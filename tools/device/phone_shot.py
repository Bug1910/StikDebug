"""Grab one iPhone screenshot to the given path."""
import asyncio, sys
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.remote.userspace_tunnel import establish_userspace_rsd
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

async def main():
    devs = await list_devices()
    rsd = await establish_userspace_rsd(serial=devs[0].serial)
    async with DvtProvider(rsd) as dvt:
        async with Screenshot(dvt) as s:
            open(sys.argv[1], 'wb').write(await s.get_screenshot())
    print('saved')

asyncio.run(main())
