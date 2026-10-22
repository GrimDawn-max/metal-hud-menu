# What the metrics mean

**All of these are system-wide, not per-game.** The HUD draws over one game, so
it is easy to read them as that game's figures — they are not. "GPU usage 90%"
means the whole GPU is 90% busy, whatever is using it.

| element | shown as | meaning |
|---|---|---|
| `cpuusage` | CPU usage | Share of total CPU capacity in use across all cores, whole machine. |
| `gpuusage` | GPU usage | Share of GPU capacity in use. Sustained 100% usually means the GPU is the limit. |
| `cputemp` | CPU temperature | Hottest CPU sensor, °C. |
| `gputemp` | GPU temperature | Hottest GPU sensor, °C. |
| `fans` | Fan 1, Fan 2 | Measured fan speed, RPM. `0` means stopped, which is normal when cool — and on a fanless Mac there are no rows. |
| `cpupower` | CPU power est. | Package CPU power draw, watts. |
| `ecorepower` | E-core power | Efficiency-core cluster power. |
| `pcorepower` | P-core power | Performance-core clusters, summed. E + P equals the package figure, so this shows where work is actually running — a game on E-cores behaves very differently from one on P-cores. |
| `gpupower` | GPU power | GPU power draw, watts. |
| `systempower` | System power | Whole-machine power draw, watts. Larger than CPU + GPU because it includes display, memory, storage and everything else. |
| `free` | Free RAM | Memory not in use. Low free RAM is not itself a problem on macOS. |
| `inactive` | Free + inactive RAM | Free plus memory holding cached data that can be reclaimed. Usually the more meaningful "available" figure. |
| `swap` | Swap used | Memory paged to disk. Anything above zero while gaming is worth noticing; growing swap usually means stutter. |
| `thermal` | Thermal pressure | macOS's own assessment: Nominal, Fair, Serious or Critical. Anything past Nominal means the system is throttling. |
| `netdown` / `netup` | Network down / up | Combined Wi-Fi and Ethernet throughput, MB/s. Tunnels (`utun*`) and AWDL are excluded — VPN traffic also crosses the physical link, so counting both would double it. |
| `wifidown` / `wifiup` | Wi-Fi down / up | Wi-Fi only. |
| `ethdown` / `ethup` | Ethernet down / up | Wired only, including USB and Thunderbolt adapters. |
| `diskread` / `diskwrite` | Disk read / write | Internal storage, MB/s. |
| `extdiskread` / `extdiskwrite` | Ext disk read / write | External storage, MB/s. Worth watching separately if games are installed on an external drive — the two are very different figures. |

## How rows are shown

**Paired directions share a row.** With both sides enabled, disk and network
appear as one line — `Disk R/W  772/31 KB/s` — rather than two near-identical
labels. Enable only one side and it gets its own row.

**Units follow the rate.** Below 1 MB/s the figure is KB/s with no decimals,
then MB/s with one, then GB/s with two. So an idle link reads `47/12 KB/s`, a
busy SSD `5.20/0.00 GB/s`, and nothing ever renders as `5120.0 MB/s`. A paired
row uses one scale for both sides, chosen from the larger, so the two numbers
stay comparable — the quiet side of a very lopsided pair can therefore read as
zero.

**Numbers are column-aligned.** Labels are padded to the widest in the current
selection, so every value starts in the same column. The padding adapts, so a
small selection does not leave a wide gap.

**Disk and network are averaged over about four seconds.** Measured at a game's
start screen, two seconds in five were exactly zero and one carried a 672 KB/s
burst, because the page cache absorbs almost everything. An instantaneous
reading is therefore mostly zero with occasional spikes; the average shows
sustained throughput instead, at the cost of lagging a real burst by a second
or two. Temperatures and power are already smooth and are not averaged.

## Notes

**"Sampling..."** appears on the first reading of any rate-based metric (power,
network, disk). They are cumulative counters, so a rate needs two samples.

**"Unavailable"** means the hardware or OS does not expose that value on this
machine, not that something is broken. Fan rows are absent on fanless Macs.

**"CPU power est."** is labelled an estimate because on some hardware it is
derived from per-cluster rails rather than measured directly.

**E-core / P-core power** are *cluster* figures, not per-core. `EACC_CPU` is the
whole efficiency cluster and `PACC*_CPU` the performance clusters summed; they
add up to exactly the package figure. Per-core channels exist but sum to only
76-96% of the package, so they are not used.

**Internal vs external disk** is taken from the device's own
`Physical Interconnect Location`, not inferred from the mount path. Disk images
and network mounts appear as neither.

## Where the numbers come from

Temperatures and fan speeds are read from SMC; power, and the E/P-core split,
from IOReport's Energy Model group; memory from `vm_stat` and `sysctl`; network
from `getifaddrs`, with interface type from SystemConfiguration (`if_data`
reports Ethernet for Wi-Fi too, so it cannot distinguish them); disk from
IOKit's block storage statistics. None of it needs
root. IOReport and SMC are private interfaces, so values may move between macOS
releases.
