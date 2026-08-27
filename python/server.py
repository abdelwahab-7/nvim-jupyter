import sys
import json
import asyncio
import logging
import base64
import os
import uuid
import threading
import queue
from jupyter_client.manager import AsyncKernelManager

logging.basicConfig(filename='/tmp/nvim_jupyter_daemon.log', level=logging.DEBUG)

IMAGE_DIR = "/tmp/nvim_jupyter_images"
os.makedirs(IMAGE_DIR, exist_ok=True)

class FileWriterThread(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.q = queue.Queue()
        
    def run(self):
        while True:
            item = self.q.get()
            if item is None:
                break
            filepath, text = item
            try:
                with open(filepath, "a") as f:
                    f.write(text)
            except Exception:
                pass

file_writer = FileWriterThread()
file_writer.start()

async def read_stdin(q: asyncio.Queue):
    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    try:
        await loop.connect_read_pipe(lambda: protocol, sys.stdin)
    except Exception as e:
        logging.error(f"Failed to connect read pipe: {e}")
        return
    
    while True:
        line = await reader.readline()
        if not line:
            break
        try:
            logging.debug(f"Received JSON: {line.decode('utf-8').strip()}")
            msg = json.loads(line.decode('utf-8'))
            await q.put(msg)
        except Exception as e:
            logging.error(f"JSON Parse Error: {e}")

class JupyterDaemon:
    def __init__(self):
        self.km = AsyncKernelManager(kernel_name='python3')
        self.kc = None
        self.msg_to_cell = {}
    
    def send(self, method, params):
        msg = json.dumps({"jsonrpc": "2.0", "method": method, "params": params})
        logging.debug(f"Sending JSON: {msg}")
        sys.stdout.write(msg + '\n')
        sys.stdout.flush()

    async def start(self):
        logging.info("Starting kernel...")
        await self.km.start_kernel(extra_arguments=[
            "--IPKernelApp.iopub_msg_rate_limit=0",
            "--IPKernelApp.iopub_data_rate_limit=0"
        ])
        self.kc = self.km.client()
        self.kc.start_channels()
        
        # ZeroMQ by default drops messages if its queue exceeds 1000.
        # This allows millions of print statements to queue safely without loss.
        import zmq
        if hasattr(self.kc.iopub_channel, 'socket'):
            self.kc.iopub_channel.socket.setsockopt(zmq.RCVHWM, 0)
            
        logging.info("Kernel channels started.")
        
        # Inject hidden setup code to force Pandas to format tables perfectly in text
        # by disabling width wrapping and expanding column limits
        setup_code = """
import sys
import subprocess

try:
    import tabulate
except ImportError:
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "tabulate"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

try:
    import pandas as pd
    pd.set_option('display.width', 10000)
    pd.set_option('display.max_columns', 1000)
    pd.set_option('display.max_colwidth', 1000)
    
    from IPython import get_ipython
    ipy = get_ipython()
    if ipy:
        def custom_df_formatter(df, p, cycle):
            try:
                p.text(df.to_markdown(tablefmt='grid'))
            except Exception:
                p.text(df.to_string())
        
        plain_formatter = ipy.display_formatter.formatters['text/plain']
        plain_formatter.for_type(pd.DataFrame, custom_df_formatter)
        
        # Inject Variable Explorer Hook
        import json
        from IPython.display import display
        def broadcast_variables():
            vars_info = []
            for k, v in ipy.user_ns.items():
                if k.startswith('_') or type(v).__name__ in ('module', 'function', 'builtin_function_or_method', 'type'):
                    continue
                info = {"name": k, "type": type(v).__name__}
                try:
                    if hasattr(v, 'shape'):
                        info['details'] = str(v.shape)
                    elif isinstance(v, (list, dict, set, tuple, str)):
                        info['details'] = f"len: {len(v)}"
                    else:
                        val = repr(v)
                        if len(val) > 20: val = val[:17] + "..."
                        info['details'] = val
                    vars_info.append(info)
                except Exception:
                    pass
            display({'application/vnd.nvim.variables+json': vars_info}, raw=True)
            
        ipy.events.register('post_execute', broadcast_variables)
        
        # Helper for extracting cell-local variables on demand
        def get_nvim_local_vars(var_names):
            vars_info = []
            for k in var_names:
                if k in ipy.user_ns:
                    v = ipy.user_ns[k]
                    info = {"name": k, "type": type(v).__name__}
                    try:
                        if hasattr(v, 'shape'):
                            info['details'] = str(v.shape)
                        elif isinstance(v, (list, dict, set, tuple, str)):
                            info['details'] = f"len: {len(v)}"
                        else:
                            val = repr(v)
                            if len(val) > 20: val = val[:17] + "..."
                            info['details'] = val
                        vars_info.append(info)
                    except Exception:
                        pass
            return json.dumps(vars_info)
except Exception:
    pass
"""
        self.kc.execute(setup_code, silent=True)
        
        asyncio.create_task(self.listen_iopub())
        asyncio.create_task(self.listen_stdin())
        asyncio.create_task(self.listen_shell())
        self.send("log", {"msg": "Kernel started successfully."})

    async def listen_iopub(self):
        logging.info("Started listening to IOPub...")
        while True:
            try:
                # get_msg is async in AsyncKernelClient channels
                msg = await self.kc.iopub_channel.get_msg()
                msg_type = msg['header']['msg_type']
                parent_id = msg['parent_header'].get('msg_id')
                content = msg['content']
                
                cell_data = self.msg_to_cell.get(parent_id)
                if cell_data is None:
                    continue

                cell_id = cell_data["cell_id"]
                bufnr = cell_data["bufnr"]
                output_id = cell_data["output_id"]

                if msg_type == 'stream':
                    text = content['text']
                    file_writer.q.put((f"/tmp/nvim_jupyter_output_{cell_id}.log", text))

                if cell_data.get("truncated"):
                    # Suppress further output messages to Neovim if we already truncated
                    if msg_type == 'status':
                        state = content.get('execution_state')
                        if state == 'idle':
                            final_status = "error" if cell_data.get("has_error") else "success"
                            self.send("status", {"cell_id": cell_id, "bufnr": bufnr, "status": final_status})
                    continue

                if msg_type == 'stream':
                    lines = text.count('\n') + 1
                    cell_data["lines_count"] += lines
                    if cell_data["lines_count"] > 1000:
                        cell_data["truncated"] = True
                        self.send("output", {"cell_id": cell_id, "bufnr": bufnr, "output_id": output_id, "type": "stream", "text": text[:1000] + "\n... [Output truncated. Press <leader>vo to open full output] ...\n"})
                    else:
                        self.send("output", {"cell_id": cell_id, "bufnr": bufnr, "output_id": output_id, "type": "stream", "text": text})
                elif msg_type == 'execute_result' or msg_type == 'display_data':
                    # Intercept Variable Explorer broadcasts
                    if 'application/vnd.nvim.variables+json' in content['data']:
                        vars_data = content['data']['application/vnd.nvim.variables+json']
                        self.send("variables", {"variables": vars_data})
                        continue
                        
                    # Check for image data first
                    if 'image/png' in content['data']:
                        img_data = content['data']['image/png']
                        img_bytes = base64.b64decode(img_data)
                        img_filename = f"plot_{uuid.uuid4().hex[:8]}.png"
                        img_filepath = os.path.join(IMAGE_DIR, img_filename)
                        with open(img_filepath, "wb") as f:
                            f.write(img_bytes)
                        
                        self.send("output", {"cell_id": cell_id, "bufnr": bufnr, "output_id": output_id, "type": "image", "filepath": img_filepath})
                    elif 'text/plain' in content['data']:
                        self.send("output", {"cell_id": cell_id, "bufnr": bufnr, "output_id": output_id, "type": "data", "data": content['data']})
                    elif 'text/html' in content['data']:
                        self.send("output", {"cell_id": cell_id, "bufnr": bufnr, "output_id": output_id, "type": "html", "html": content['data']['text/html']} )
                elif msg_type == 'error':
                    cell_data["has_error"] = True
                    self.send("output", {"cell_id": cell_id, "bufnr": bufnr, "output_id": output_id, "type": "error", "traceback": content['traceback']})
                elif msg_type == 'status':
                    state = content.get('execution_state')
                    if state:
                        self.send("kernel_status", {"state": state})
                        
                    if state == 'idle':
                        final_status = "error" if cell_data.get("has_error") else "success"
                        self.send("status", {"cell_id": cell_id, "bufnr": bufnr, "status": final_status})
            except Exception as e:
                logging.error(f"IOPub Error: {e}")
                
    async def listen_stdin(self):
        logging.info("Started listening to STDIN...")
        while True:
            try:
                msg = await self.kc.stdin_channel.get_msg()
                msg_type = msg['header']['msg_type']
                if msg_type == 'input_request':
                    prompt = msg['content'].get('prompt', '')
                    self.send("input_request", {"prompt": prompt})
            except Exception as e:
                logging.error(f"STDIN Error: {e}")
                    
    async def listen_shell(self):
        logging.info("Started listening to Shell...")
        while True:
            try:
                msg = await self.kc.shell_channel.get_msg()
                msg_type = msg['header']['msg_type']
                if msg_type == 'execute_reply':
                    parent_id = msg['parent_header'].get('msg_id')
                    cell_data = self.msg_to_cell.get(parent_id)
                    if not cell_data:
                        continue
                    
                    user_expr = msg['content'].get('user_expressions', {})
                    if 'nvim_local_vars' in user_expr:
                        res = user_expr['nvim_local_vars']
                        if res.get('status') == 'ok':
                            try:
                                import json
                                raw_text = res['data']['text/plain']
                                # The string comes wrapped in quotes, e.g., "'[...]'"
                                raw_text = raw_text.strip("'\"")
                                # Also python might escape quotes
                                raw_text = raw_text.replace("\\'", "'")
                                raw_text = raw_text.replace("\\\"", "\"")
                                # If it's still failing due to python repr escaping, safely load it
                                vars_data = json.loads(raw_text)
                                self.send("local_variables", {"cell_id": cell_data["cell_id"], "variables": vars_data})
                            except Exception as e:
                                logging.error(f"Failed to parse local vars: {e}")
            except Exception as e:
                logging.error(f"Shell Error: {e}")

    async def execute(self, cell_id, bufnr, output_id, code):
        self.send("status", {"cell_id": cell_id, "bufnr": bufnr, "status": "running"})
        logging.info(f"Executing cell {cell_id}...")
        
        log_file = f"/tmp/nvim_jupyter_output_{cell_id}.log"
        if os.path.exists(log_file):
            try:
                os.remove(log_file)
            except Exception:
                pass
        
        import ast
        assigned_vars = {}
        try:
            class AssignVisitor(ast.NodeVisitor):
                def _extract_names(self, target):
                    if isinstance(target, ast.Name):
                        assigned_vars[target.id] = True
                    elif isinstance(target, (ast.Tuple, ast.List)):
                        for elt in target.elts:
                            self._extract_names(elt)

                def visit_Assign(self, node):
                    for target in node.targets:
                        self._extract_names(target)
                    self.generic_visit(node)
                    
                def visit_AnnAssign(self, node):
                    self._extract_names(node.target)
                    self.generic_visit(node)

            tree = ast.parse(code)
            AssignVisitor().visit(tree)
        except Exception:
            pass
            
        user_expr = {}
        if assigned_vars:
            var_names = list(assigned_vars.keys())
            user_expr["nvim_local_vars"] = f"get_nvim_local_vars({var_names})"
            
        msg_id = self.kc.execute(code, user_expressions=user_expr)
        self.msg_to_cell[msg_id] = {
            "cell_id": cell_id, 
            "bufnr": bufnr, 
            "output_id": output_id, 
            "has_error": False,
            "lines_count": 0,
            "truncated": False
        }

    async def interrupt(self):
        if self.kc is not None:
            await self.km.interrupt_kernel()

async def main():
    q = asyncio.Queue()
    asyncio.create_task(read_stdin(q))
    
    daemon = JupyterDaemon()
    await daemon.start()
    
    while True:
        msg = await q.get()
        method = msg.get('method')
        params = msg.get('params', {})
        
        if method == 'execute':
            await daemon.execute(params.get('cell_id'), params.get('bufnr'), params.get('output_id'), params.get('code'))
        elif method == 'input_reply':
            daemon.kc.input(params.get('value', ''))
        elif method == 'interrupt':
            await daemon.interrupt()
        elif method == 'stop':
            await daemon.km.shutdown_kernel()
            break

if __name__ == '__main__':
    asyncio.run(main())

