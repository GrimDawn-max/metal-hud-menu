# What the Mac Stats rows mean

**All of these are system-wide, not per-game.** The HUD draws over one game, so it is easy to read
them as that game's figures; they are not. "GPU usage 90%" means the whole GPU is 90% busy,
whatever is using it.

**Each row is one headline figure, not a breakdown.** Several combine many sensors or devices into
one number, as described below. For per-core, per-sensor or per-device detail, use a dedicated app
(TG Pro, iStat Menus, Activity Monitor).

| Stat | HUD row | Meaning |
|---|---|---|
| `cpuusage` | CPU usage | Share of total CPU capacity in use, all cores. |
| `cpuclock` | CPU E-core clock, CPU P-core clock | Average clock of each cluster while active, MHz. |
| `cputemp` | CPU temperature | **Differs by chip at present.** On an M4 Max: the hottest CPU core, matched to TG Pro. On other chips: the average of all CPU sensors, which reads lower than the hottest core (about 18 °C lower on an M1 Max under load). |
| `cpupower` | CPU power est. | CPU package power, watts. On chips without per-cluster rails (M1 Max) it is read from the package channel instead. |
| `ecorepower` | CPU E-core power | Efficiency-core cluster power, watts. |
| `pcorepower` | CPU P-core power | Performance-core clusters, summed. E + P equals the package figure, so the pair shows where the work runs. |
| `gpuusage` | GPU usage | Share of time the GPU is busy at any speed. |
| `gpuclock` | GPU clock | Average GPU clock while active, MHz. 60% usage at a low clock means plenty of headroom. |
| `gputemp` | GPU temperature | Hottest GPU cluster, matched to TG Pro on M4 Max and M1 Max. |
| `gpupower` | GPU power | GPU power draw, watts. |
| `aneusage` | ANE usage | Neural Engine activity, estimated from its memory-bandwidth requests. |
| `mempressure` | Memory pressure | As Activity Monitor shows it: Normal, Warning or Critical. |
| `swap` | Memory swap used | Memory paged to disk. Growing swap while gaming usually means stutter. |
| `free` | Memory free | Memory not in use. Low free memory is not itself a problem on macOS. |
| `inactive` | Memory free+inactive | Free plus reclaimable cache: usually the more meaningful "available" figure. |
| `diskio` | Disk R/W | Internal storage, read / write. |
| `extdiskio` | External disk R/W | External storage, read / write. Worth watching if games are installed on an external drive. |
| `network` | Network D/U | All physical connections combined, down / up. |
| `wifi` | Wi-Fi D/U | Wi-Fi only. |
| `wired` | Wired D/U | Wired connections only: Ethernet, including USB and Thunderbolt adapters. |
| `systempower` | System power | Whole-machine power draw, watts: display, memory, storage and everything else too. |
| `thermal` | Thermal pressure | macOS's own assessment: Nominal, Fair, Serious or Critical. Past Nominal, the system is throttling. |
| `fans` | Fan 1, Fan 2 | Measured fan speed, RPM. 0 means stopped, normal when cool. No rows on a fanless Mac. |

## Disk and network rows

**Both directions share a row:** read / write for disks, down / up for networks, as in
`Disk R/W  772/31 KB/s`.

**One unit for both numbers,** chosen from the larger: KB/s with no decimals, then MB/s with one,
then GB/s with two. The two numbers stay comparable, so the quiet side of a lopsided pair can read
as zero, and nothing renders as `5120.0 MB/s`.

**Averaged over about four seconds.** The page cache absorbs most disk activity, so an instant
reading is mostly zero with occasional spikes; the average shows sustained throughput, at the cost
of lagging a burst by a second or two.

**Network excludes tunnels and AWDL.** VPN traffic also crosses the physical link, so counting both
would double it. Interface type comes from SystemConfiguration.

**Internal vs external disk** comes from each device's reported interconnect, not the mount path.
Disk images and network mounts count as neither.

## Notes

**"Sampling..."** appears on the first reading of any rate (power, disk, network): it needs two
samples.

**"Unavailable"** means this Mac or macOS version does not expose that value.

**Models differ.** Sensor names, power channels and clock tables vary between Apple chips, and only
the chips named above have been checked against another tool. A figure on an unchecked chip may
use a fallback, as CPU temperature does.

## Where the numbers come from

Temperatures and fan speeds from the SMC; power, clocks and the E/P split from IOReport; memory from
`vm_statistics` and `sysctl`; network from `getifaddrs`; disk from IOKit block-storage statistics.
None of it needs root. IOReport and the SMC are private interfaces, so values may change between
macOS releases.
