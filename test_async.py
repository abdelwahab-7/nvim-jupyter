import asyncio
from jupyter_client.manager import AsyncKernelManager

async def main():
    km = AsyncKernelManager(kernel_name='python3')
    await km.start_kernel()
    kc = km.client()
    kc.start_channels()
    
    await kc.wait_for_ready()
    print("Kernel ready!")
    
    msg_id = kc.execute("print('Hello from test!')")
    print(f"Sent execute {msg_id}")
    
    while True:
        msg = await kc.iopub_channel.get_msg()
        print(msg['header']['msg_type'])
        if msg['header']['msg_type'] == 'stream':
            print("STREAM:", msg['content']['text'])
            break

asyncio.run(main())
