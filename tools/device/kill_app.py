"""Find an iPhone app's running process by bundle id and stop it (DVT ProcessControl)."""
import asyncio, sys
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.remote.userspace_tunnel import establish_userspace_rsd
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

async def main():
    devs = await list_devices()
    rsd = await establish_userspace_rsd(serial=devs[0].serial)
    async with DvtProvider(rsd) as dvt:
        async with DeviceInfo(dvt) as di:
            procs = di.proclist()
            if asyncio.iscoroutine(procs): procs = await procs
        hits = [p for p in procs if p.get('bundleIdentifier') == sys.argv[1]]
        print('running:', [(p.get('pid'), p.get('name')) for p in hits])
        async with ProcessControl(dvt) as pc:
            for p in hits:
                r = pc.kill(p['pid'])
                if asyncio.iscoroutine(r): await r
                print('killed', p['pid'])

asyncio.run(main())
