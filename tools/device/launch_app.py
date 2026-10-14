"""Launch an iPhone app by bundle id (DVT ProcessControl), without killing a running instance."""
import asyncio, sys
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.remote.userspace_tunnel import establish_userspace_rsd
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

async def main():
    devs = await list_devices()
    rsd = await establish_userspace_rsd(serial=devs[0].serial)
    async with DvtProvider(rsd) as dvt:
        async with ProcessControl(dvt) as pc:
            r = pc.launch(sys.argv[1], kill_existing=False)
            if asyncio.iscoroutine(r):
                r = await r
            print('pid', r)

asyncio.run(main())
