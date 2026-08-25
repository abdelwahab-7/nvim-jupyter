import asyncio
from jupyter_client.manager import AsyncKernelManager


async def main():
    km = AsyncKernelManager(kernel_name="python3")
    await km.start_kernel()
    kc = km.client()
    kc.start_channels()

    await kc.wait_for_ready()

    # Run a code block that asks for input
    msg_id = kc.execute("name = input('Enter name: ')\nprint('Hello', name)")
    print(f"Sent execute {msg_id}")

    while True:
        try:
            # We must check BOTH iopub and stdin
            # Actually, let's just do it sequentially for testing
            msg = await kc.stdin_channel.get_msg(timeout=1.0)
            print("STDIN:", msg["header"]["msg_type"], msg["content"])
            if msg["header"]["msg_type"] == "input_request":
                kc.input("Antigravity")
                print("Sent input_reply")
        except Exception:
            pass

        try:
            msg = await kc.iopub_channel.get_msg(timeout=0.1)
            print("IOPUB:", msg["header"]["msg_type"])
            if msg["header"]["msg_type"] == "stream":
                print("STREAM:", msg["content"]["text"])
                break
        except Exception:
            pass


asyncio.run(main())
