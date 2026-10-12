# System Status

Open the shelf with **⌘⇧Space**, search for **System Status**, use the arrows to select it, and press **Enter**. You can also click its launcher result. Search aliases include battery, memory, RAM, storage, disk, network, Wi-Fi, Ethernet, VPN, and their Russian equivalents. The Russian app name is **Состояние системы**.

The overview shows battery charge and power source, memory usage and macOS memory pressure, available storage on the startup Data volume, and the active network connection with upload/download rates. Thin meters show battery charge and available storage; compact charts show recent memory usage and network traffic. **Backspace** returns to Apps; **Esc** or **⌘W** closes the shelf. Buttons expose their shortcuts in tooltips and accessibility descriptions. System Status can be disabled in **Settings → Built-in Apps**.

Battery estimates appear only when macOS supplies a positive estimate, and are labelled “About”. Macs without an internal battery say so. A plugged-in battery that is not charging is distinct from a full battery. Memory warnings follow macOS memory pressure; high usage alone is not a warning. Compressed memory reports its physical footprint, and swap is shown separately. An unavailable pressure or swap reading does not hide the other memory values.

Storage reports `/System/Volumes/Data` once, using its volume name, total capacity and currently available bytes. It does not add the read-only system volume's shared APFS capacity or count purgeable space as already free. Low space means less than 5% of capacity or 5 GB, whichever is larger. Storage uses decimal units; memory uses binary units through the localized macOS byte formatter.

Network connection means that macOS has an active primary route. It does not verify internet access or send a reachability request. Rates count one primary interface, preferring a primary VPN tunnel when exposed by macOS, rather than adding the tunnel and physical transport together. Split-tunnel traffic on other interfaces is not included. A change of interface, counter reset, disconnect, or resume starts a fresh measurement interval. Zero traffic is shown as zero; a first sample says “Measuring traffic…”. Wi-Fi names are not read, so no Location permission is required.

## Sampling and failure states

All readings stay in memory on this Mac. The feature does not persist metrics, contact a server, spawn shell commands, or require additional permissions. Independent battery, memory, storage and network probes prevent one unavailable resource from hiding the others.

Readings distinguish loading, unavailable, read failure, valid zero and stale data. A failed refresh retains a previous successful reading with a stale label and last-reading time. Closing the app or suspending for sleep/lock marks previous readings stale and clears traffic rates. The next open/resume immediately refreshes them without moving focus or changing navigation.

A serial background actor samples battery, memory and networking every two seconds while the overview is open; capacity is cached for 15 seconds. There is no resource polling while another shelf app is active or the shelf is hidden. Sleep and lock suspension reasons must both clear before sampling can resume. In-flight results from a previous session are discarded.

Memory and network charts retain up to 60 seconds and 31 samples, only while this overview is open. They show a collecting state until two readings are available; the time label expands from the available span to a minute. Closing, sleep/lock, or a failed probe clears the affected history. Changing network interfaces also starts a fresh network chart. Both traffic lines share a vertical scale; download is solid blue and upload is dashed gray. Zero traffic remains a valid flat line. The RAM chart labels its byte range and keeps at least 256 MiB or 1/16 of total memory in its vertical span, capped at physical capacity, so small fluctuations are not magnified. Charts add no timers, animation or probes, and nothing is written to disk.

Sources: IOKit [power-source descriptions](https://github.com/opensource-apple/IOKitUser/blob/master/ps.subproj/IOPowerSources.h), Mach [host statistics](https://developer.apple.com/documentation/kernel/1502863-host_statistics64), read-only `kern.memorystatus_vm_pressure_level` and `vm.swapusage` sysctls, Foundation volume resource values, and [SystemConfiguration's dynamic store](https://developer.apple.com/documentation/systemconfiguration/scdynamicstore-gb2) with 64-bit `NET_RT_IFLIST2` interface counters. If a kernel value is unavailable, the UI says so.

## Validation and overhead

`./polka desktop core` runs the real AppKit keyboard and mouse flows with synthetic normal, warning, and partly unavailable readings in the managed macOS VM. Screenshots are copied to `artifacts/desktop/native-smoke/system-status-{normal,warning,unavailable}.png`. No host clipboard, personal profile or other app instance is used. The older Electron `tests/desktop/desktop-test.ts` mentioned in issue #59 has been replaced by this native harness.

Core tests cover battery transitions and estimates, pressure normalization, APFS capacity validation, network counter resets and interface changes, independent failure/stale states, and bilingual aliases. UI tests verify sampling stops while closed/suspended, immediate resume, unchanged navigation, and keyboard scoping. Platform tests read actual local resources and verify network warm-up resets.

Measure local probe overhead separately from correctness tests:

```sh
mkdir -p artifacts/system-status
POLKA_MEASURE_SYSTEM_STATUS=1 \
POLKA_SYSTEM_STATUS_MEASUREMENT="$PWD/artifacts/system-status/overhead.json" \
swift test --package-path native-app --filter SystemResourceProbeTests
```

The ten-sample session uses the production two-second interval and records mean/max probe latency, process CPU time, wall time and each probe's state. The debug XCTest measurement includes task/test scheduling and excludes shelf rendering; it is not a guarantee for every Mac. See the generated JSON for the measured values.

For the complete monitoring and rendering overhead inside the managed VM, run `POLKA_NATIVE_SYSTEM_STATUS_MEASURE=1 ./polka desktop core`. It measures a ten-second synthetic overview baseline and ten seconds with live resource sampling in the same isolated app process, recording CPU percentage, sample count and physical memory footprint in `artifacts/desktop/native-smoke/system-status-overhead.json`. This optional measurement does not change the desktop assertions or timeouts.

Before adding charts, measured on 12 October 2026 in the managed macOS 27 VM with the debug app: five live samples in 10.60 seconds, 0.99% of one CPU core while sampling/rendering, and physical footprint increasing from 38,209,792 to 38,242,560 bytes (+32 KiB). The ten-second baseline was 1.31%, so this short run is too noisy to estimate incremental CPU cost by subtraction. All four probes succeeded. These are local VM observations, not hosted CI timings or a performance guarantee.

With charts and meters, the final debug VM run recorded five samples in 10.27 seconds: 1.60% of one CPU core while sampling/rendering versus 1.29% for the static overview, and physical footprint increasing from 39,635,392 to 40,241,600 bytes (+592 KiB). All four probes succeeded.
