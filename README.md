# MedtrumKit

Medtrum Bluetooth PumpManager For Loop.

## Supported Medtrum versions
- 200U (both MD0201 & MD8201)
- 300U (MD8301)

## Connection

MedtrumKit connects to the patch the way OmnipodKit does. While the app is in the foreground the link is held, so in-app commands are instant. In the background it connects on demand: for a command or a status read, then it hangs up about 4 s after the last one (`MedtrumKit.idleDisconnectSeconds` in UserDefaults). The link stays up in the background while a bolus runs (its progress only arrives as notifications), while a patch is set up, when the app needs the pump as its heartbeat (a CGM that can't wake the loop), and with silent tones on. A patch handed over by another controller is never held, so that controller can take it back. Alarms such as an occlusion or an expired patch are therefore seen at the next connect, within one loop cycle; the patch beeps by itself in the meantime.

## Handing the patch to another controller (Watch Loop)

`MedtrumPumpManager` implements LoopKit's `DeviceConfigurationSharing`, `ExclusiveDeviceControl` and `PumpDeliveryOdometer`, as OmnipodKit does (loopandlearn/OmnipodKit#177). The export carries the pump base's serial number and session token and the doses in flight; each device keeps its own Bluetooth handle in `localState`, and a device without one finds the base by its serial number. The delivered total is what the patch has given since its first reservoir reading, in 0.05 U pulses. When a bolus under way ends comes from the patch, as OmnipodKit does: the units it has still to give at 1.5 U/min, with the amount from this controller's dose or, for another controller's bolus, from the patch's history record of it (`GET_RECORD`). The `MedtrumKit-watchOS` target builds the kit without its UI for the watch.

Medtrum has no session counter like Omnipod's, so a controller that kept a patch it handed over spots the other controller's use in what the patch reports when it connects: a temp basal running, or a bolus in the history records new since its last connection, that started after it last heard the patch. Patch times are converted with the clock offset the last `GET_TIME` measured (read every 30 min while connected; nothing sets the patch's clock but activation and the user), within 5 s, or 60 s when that measurement is over an hour old. The patch never starts either by itself; records it does write by itself (alarms, suspends, a temp basal running out, daily totals) are ignored. A controller that finds one stands aside as OmnipodKit's does: it keeps its doses in flight, books none of the other's delivery, sends nothing and stops connecting until its host takes control again (`otherControllerDetectedAt`). Only a patch that was exported or adopted is checked, and the connection after a take or an adopt is skipped. Each connection logs how the history moved and each record it read, with its type.

## For more information

Please join loop zulipchat at https://loop.zulipchat.com/

Or the Trio discord at https://discord.gg/FnwFEFUwXE
