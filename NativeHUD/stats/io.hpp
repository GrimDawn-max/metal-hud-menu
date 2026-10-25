// Disk and network throughput.
//
// Both are cumulative byte counters, so a rate needs two samples; the first
// read reports Sampling, as the power sources do.
//
// Network: getifaddrs() with AF_LINK gives per-interface if_data counters. No
// privileges needed. Loopback is excluded, and so are interfaces that are down,
// since counting lo0 would roughly double any local traffic.
//
// Disk: IOBlockStorageDriver publishes a Statistics dictionary per device with
// cumulative bytes read and written. Only physical block devices appear, so
// disk images and network mounts are not counted.
#pragma once
#include <chrono>
#include <cstdint>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <sys/socket.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <string>
#include <array>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>

namespace hudstats::io {

enum class Status { Unavailable, Sampling, Ready };
struct Rate { Status status=Status::Unavailable; double readBps=0, writeBps=0; };

namespace detail {

enum class Link { Any, WiFi, Ethernet };

// if_data.ifi_type reports IFT_ETHER for Wi-Fi as well as wired, so the type
// comes from SystemConfiguration instead. Only real physical links are counted:
// including utun*/awdl0 would double-count, since VPN traffic also crosses the
// physical interface underneath.
inline std::string linkType(const char *bsd) {
  static CFArrayRef all=SCNetworkInterfaceCopyAll();
  if(!all) return {};
  for(CFIndex i=0;i<CFArrayGetCount(all);i++) {
    auto n=(SCNetworkInterfaceRef)CFArrayGetValueAtIndex(all,i);
    CFStringRef name=SCNetworkInterfaceGetBSDName(n);
    char buf[32]="";
    if(name) CFStringGetCString(name,buf,sizeof(buf),kCFStringEncodingUTF8);
    if(strcmp(buf,bsd)) continue;
    CFStringRef t=SCNetworkInterfaceGetInterfaceType(n);
    char type[64]="";
    if(t) CFStringGetCString(t,type,sizeof(type),kCFStringEncodingUTF8);
    return type;
  }
  return {};
}

inline bool networkBytes(Link want, uint64_t &in, uint64_t &out) {
  struct ifaddrs *list=nullptr;
  if(getifaddrs(&list)!=0||!list) return false;
  in=out=0;
  bool any=false;
  for(auto *p=list;p;p=p->ifa_next) {
    if(!p->ifa_addr||p->ifa_addr->sa_family!=AF_LINK) continue;
    if(!(p->ifa_flags&IFF_UP)||(p->ifa_flags&IFF_LOOPBACK)) continue;
    auto *d=(struct if_data *)p->ifa_data;
    if(!d) continue;
    std::string type=linkType(p->ifa_name);
    bool wifi=(type=="IEEE80211"), eth=(type=="Ethernet");
    if(!wifi&&!eth) continue;
    if(want==Link::WiFi&&!wifi) continue;
    if(want==Link::Ethernet&&!eth) continue;
    in+=d->ifi_ibytes;
    out+=d->ifi_obytes;
    any=true;
  }
  freeifaddrs(list);
  return any;
}

// Internal and external are reported separately: on a machine that runs games
// from an external drive, a combined figure mixes game I/O with whatever the
// system is doing on the boot disk. The distinction comes from the device's
// own Protocol Characteristics, not from guesswork.
inline bool diskBytes(bool wantExternal, uint64_t &read, uint64_t &written) {
  CFMutableDictionaryRef match=IOServiceMatching(kIOBlockStorageDriverClass);
  if(!match) return false;
  io_iterator_t it{};
  if(IOServiceGetMatchingServices(kIOMainPortDefault,match,&it)!=KERN_SUCCESS) return false;
  read=written=0;
  bool any=false;
  for(io_registry_entry_t e;(e=IOIteratorNext(it));IOObjectRelease(e)) {
    bool external=false;
    CFDictionaryRef pc=(CFDictionaryRef)IORegistryEntrySearchCFProperty(
        e,kIOServicePlane,CFSTR(kIOPropertyProtocolCharacteristicsKey),
        kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
    if(pc) {
      auto where=(CFStringRef)CFDictionaryGetValue(pc,CFSTR(kIOPropertyPhysicalInterconnectLocationKey));
      external=where&&CFStringCompare(where,CFSTR("External"),0)==kCFCompareEqualTo;
      CFRelease(pc);
    }
    if(external!=wantExternal) continue;
    CFDictionaryRef stats=(CFDictionaryRef)IORegistryEntryCreateCFProperty(
        e,CFSTR(kIOBlockStorageDriverStatisticsKey),kCFAllocatorDefault,0);
    if(!stats) continue;
    auto number=[&](CFStringRef key,uint64_t &into){
      auto n=(CFNumberRef)CFDictionaryGetValue(stats,key);
      long long v=0;
      if(n&&CFGetTypeID(n)==CFNumberGetTypeID()&&CFNumberGetValue(n,kCFNumberLongLongType,&v)) {
        into+=(uint64_t)v; any=true;
      }
    };
    number(CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey),read);
    number(CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey),written);
    CFRelease(stats);
  }
  IOObjectRelease(it);
  return any;
}

// Shared shape: two cumulative counters turned into a rate, averaged over a
// few seconds.
//
// Disk I/O in particular is bursty -- measured at a game's start screen, two
// seconds in five were exactly zero and one carried a 672 KB/s burst, because
// the page cache absorbs almost everything. An instantaneous one-second sample
// therefore reads 0 most of the time and spikes occasionally, which is hard to
// read. Averaging over a short window shows sustained throughput instead, at
// the cost of lagging a real burst by a second or two.
class Counter {
  static constexpr size_t Window=4;          // samples, at the 1s tick = ~4s
  bool have=false;
  uint64_t lastA=0,lastB=0;
  std::chrono::steady_clock::time_point at{};
  std::array<double,Window> histA{}, histB{};
  size_t filled=0, next=0;
public:
  Rate update(bool ok,uint64_t a,uint64_t b) {
    if(!ok) { have=false; filled=next=0; return {}; }
    auto now=std::chrono::steady_clock::now();
    if(!have) { have=true; lastA=a; lastB=b; at=now; return {Status::Sampling,0,0}; }
    double elapsed=std::chrono::duration<double>(now-at).count();
    // Counters are monotonic; a decrease means an interface or device went
    // away, so restart rather than report a negative rate.
    if(elapsed<=0||a<lastA||b<lastB) {
      lastA=a; lastB=b; at=now; filled=next=0;
      return {Status::Sampling,0,0};
    }
    histA[next]=(a-lastA)/elapsed;
    histB[next]=(b-lastB)/elapsed;
    next=(next+1)%Window;
    if(filled<Window) filled++;
    lastA=a; lastB=b; at=now;
    double sumA=0,sumB=0;
    for(size_t i=0;i<filled;i++) { sumA+=histA[i]; sumB+=histB[i]; }
    return {Status::Ready,sumA/filled,sumB/filled};
  }
};

} // namespace detail

class Sampler {
  detail::Counter net, wifi, ethernet, diskInternal, diskExternal;
public:
  Rate network(detail::Link link=detail::Link::Any) {
    uint64_t i=0,o=0;
    auto &c = link==detail::Link::WiFi ? wifi : link==detail::Link::Ethernet ? ethernet : net;
    return c.update(detail::networkBytes(link,i,o),i,o);
  }
  Rate storage(bool external) {
    uint64_t r=0,w=0;
    auto &counter = external ? diskExternal : diskInternal;
    return counter.update(detail::diskBytes(external,r,w),r,w);
  }
};

} // namespace hudstats::io
