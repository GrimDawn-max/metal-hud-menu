// MetalHUDmenu Mac stats: live system readings inside Apple's Metal HUD.
// macOS 27+: public StateReporting API. macOS 26: the private QuartzCore label API DXMT uses.
// The stat selection is read live from MetalHUDmenu's preferences (key "systemStats").
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include "stats/telemetry.hpp"
#include "stats/power.hpp"
#include "stats/io.hpp"
#include "stats/usage.hpp"

namespace {
constexpr const char *kDomain="Mac Stats";
const CFStringRef kPrefsApp=CFSTR("com.Jfishin.MetalHUDmenu");

// Keep in sync with HUDSettingsManager.systemStatCatalog.
enum Metric { CPUUsage, CPUTemp, CPUPower, ECorePower, PCorePower, GPUUsage, GPUTemp, GPUPower, Fans, SystemPower, Thermal, Free, Inactive, Swap, DiskRead, DiskWrite, ExtDiskRead, ExtDiskWrite, NetDown, NetUp, WifiDown, WifiUp, EthDown, EthUp, MetricCount };
constexpr const char *names[]={"cpuusage","cputemp","cpupower","ecorepower","pcorepower","gpuusage","gputemp","gpupower","fans","systempower","thermal","free","inactive","swap","diskread","diskwrite","extdiskread","extdiskwrite","netdown","netup","wifidown","wifiup","ethdown","ethup"};
constexpr const char *labels[]={"CPU usage","CPU temperature","CPU power est.","E-core power","P-core power","GPU usage","GPU temperature","GPU power","Fans","System power","Thermal pressure","Free RAM","Free + inactive RAM","Swap used","Disk read","Disk write","Ext disk read","Ext disk write","Network down","Network up","Wi-Fi down","Wi-Fi up","Ethernet down","Ethernet up"};
std::atomic_flag started=ATOMIC_FLAG_INIT;
dispatch_source_t timer;
bool debug=false;

// MetalHUDmenu prefs, or MHUD_SYSTEM_ELEMENTS as a test override.
void readSelection(bool enabled[MetricCount]) {
  for(int i=0;i<MetricCount;i++) enabled[i]=false;
  NSArray *list=nil;
  if(const char *env=getenv("MHUD_SYSTEM_ELEMENTS")) list=[@(env) componentsSeparatedByString:@","];
  else {
    CFPreferencesAppSynchronize(kPrefsApp);
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("systemStats"),kPrefsApp));
    if([value isKindOfClass:NSArray.class]) list=value;
  }
  for(id item in list) {
    if(![item isKindOfClass:NSString.class]) continue;
    NSString *word=[item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for(int i=0;i<MetricCount;i++) if([word isEqualToString:@(names[i])]) enabled[i]=true;
  }
}

NSString *fmt(const char *f,double v) { return [NSString stringWithFormat:@(f),v]; }

// One sample of the selected readings, as row label -> text.
NSDictionary<NSString*,NSString*> *sample(const bool on[MetricCount]) {
  NSMutableDictionary *out=[NSMutableDictionary dictionary];
  auto usage=[&](Metric m,hudstats::usage::Reading r) {
    out[@(labels[m])]=r.status==hudstats::usage::Status::Ready?fmt("%.1f%%",r.percent):r.status==hudstats::usage::Status::Sampling?@"Sampling...":@"Unavailable";
  };
  if(on[CPUUsage]) { static hudstats::usage::CPUSampler s; usage(CPUUsage,s.read()); }
  if(on[GPUUsage]) { static hudstats::usage::GPUSampler s; usage(GPUUsage,s.read()); }
  if(on[CPUTemp]||on[GPUTemp]) {
    auto t=hudstats::readTemperatures();
    if(on[CPUTemp]) out[@(labels[CPUTemp])]=t.cpuOK?fmt("%.1f C",t.cpuMaxC):@"Unavailable";
    if(on[GPUTemp]) out[@(labels[GPUTemp])]=t.gpuOK?fmt("%.1f C",t.gpuMaxC):@"Unavailable";
  }
  if(on[Fans]) {
    auto f=hudstats::readFans();
    if(!f.countOK) out[@"Fans"]=@"Unavailable";
    else if(f.fans.empty()) out[@"Fans"]=@"None";
    for(size_t i=0;i<f.fans.size();i++)
      out[[NSString stringWithFormat:@"Fan %zu",i+1]]=f.fans[i].actual?fmt("%.0f RPM",f.fans[i].rpm):@"Unavailable";
  }
  if(on[CPUPower]||on[GPUPower]||on[SystemPower]||on[ECorePower]||on[PCorePower]) {
    static hudstats::power::Sampler s;
    auto v=s.read(on[CPUPower],on[GPUPower],on[SystemPower],on[ECorePower]||on[PCorePower]);
    auto watts=[&](Metric m,hudstats::power::Reading r,const char *f) {
      out[@(labels[m])]=r.status==hudstats::power::Status::Ready?fmt(f,r.watts):r.status==hudstats::power::Status::Sampling?@"Sampling...":@"Unavailable";
    };
    if(on[SystemPower]) watts(SystemPower,v.system,"%.1f W");
    if(on[CPUPower]) watts(CPUPower,v.cpu,"~%.1f W");
    // Measured as an exact split of the package figure; see Kind::ECore.
    if(on[ECorePower]) watts(ECorePower,v.ecore,"%.2f W");
    if(on[PCorePower]) watts(PCorePower,v.pcore,"%.2f W");
    if(on[GPUPower]) watts(GPUPower,v.gpu,"%.1f W");
  }
  if(on[NetDown]||on[NetUp]||on[WifiDown]||on[WifiUp]||on[EthDown]||on[EthUp]||on[DiskRead]||on[DiskWrite]||on[ExtDiskRead]||on[ExtDiskWrite]) {
    static hudstats::io::Sampler io;
    // Three scales, so the number stays short at any speed: network idles in
    // the tens of KB/s, while an internal SSD reaches several GB/s and 10GbE
    // is over 1 GB/s. Without the top tier those read as "5120.0 MB/s".
    static const double KB=1024.0, MB=1048576.0, GB=1073741824.0;
    auto scaleFor=[](double peak)->std::pair<double,const char*>{
      if(peak>=GB) return {GB,"GB/s"};
      if(peak>=MB) return {MB,"MB/s"};
      return {KB,"KB/s"};
    };
    // Precision follows the unit so the digit count stays roughly constant and
    // no resolution is thrown away: KB/s runs to thousands so decimals are
    // pointless, while at GB/s one decimal would hide 50 MB/s steps.
    auto places=[](double div)->int{ return div==KB?0:div==MB?1:2; };
    auto rate=[&](double bps)->NSString*{
      auto [div,unit]=scaleFor(bps);
      return [NSString stringWithFormat:@"%.*f %s",places(div),bps/div,unit];
    };
    // A pair shares one scale, chosen from the larger side, so the two numbers
    // can be compared directly rather than being in different units.
    auto pairRate=[&](double a,double b)->NSString*{
      auto [div,unit]=scaleFor(a>b?a:b);
      int p=places(div);
      return [NSString stringWithFormat:@"%.*f/%.*f %s",p,a/div,p,b/div,unit];
    };
    auto mb=[&](Metric m,double bps,hudstats::io::Status st){
      out[@(labels[m])]=st==hudstats::io::Status::Ready?rate(bps)
                       :st==hudstats::io::Status::Sampling?@"Sampling...":@"Unavailable";
    };
    // Directional pairs share a row: two numbers on one line reads better than
    // two near-identical labels, and halves the height of the block.
    auto duo=[&](Metric a,Metric b,NSString *both,double x,double y,hudstats::io::Status st){
      if(on[a]&&on[b]) {
        out[both]=st==hudstats::io::Status::Ready?pairRate(x,y)
          :st==hudstats::io::Status::Sampling?@"Sampling...":@"Unavailable";
      } else {
        if(on[a]) mb(a,x,st);
        if(on[b]) mb(b,y,st);
      }
    };
    if(on[NetDown]||on[NetUp]) { auto n=io.network();
      duo(NetDown,NetUp,@"Network D/U",n.readBps,n.writeBps,n.status); }
    if(on[WifiDown]||on[WifiUp]) { auto n=io.network(hudstats::io::detail::Link::WiFi);
      duo(WifiDown,WifiUp,@"Wi-Fi D/U",n.readBps,n.writeBps,n.status); }
    if(on[EthDown]||on[EthUp]) { auto n=io.network(hudstats::io::detail::Link::Ethernet);
      duo(EthDown,EthUp,@"Ethernet D/U",n.readBps,n.writeBps,n.status); }
    if(on[DiskRead]||on[DiskWrite]) { auto d=io.storage(false);
      duo(DiskRead,DiskWrite,@"Disk R/W",d.readBps,d.writeBps,d.status); }
    if(on[ExtDiskRead]||on[ExtDiskWrite]) { auto d=io.storage(true);
      duo(ExtDiskRead,ExtDiskWrite,@"Ext disk R/W",d.readBps,d.writeBps,d.status); }
  }
  if(on[Swap]||on[Free]||on[Inactive]) {
    auto m=hudstats::readMemory();
    if(on[Swap]) out[@(labels[Swap])]=m.swapOK?fmt("%.2f GiB",m.swapUsedBytes/1073741824.0):@"Unavailable";
    if(on[Free]) out[@(labels[Free])]=m.vmOK?fmt("%.2f GiB",m.freeBytes/1073741824.0):@"Unavailable";
    if(on[Inactive]) out[@(labels[Inactive])]=m.vmOK?fmt("%.2f GiB",(m.freeBytes+m.inactiveBytes)/1073741824.0):@"Unavailable";
  }
  if(on[Thermal]) {
    NSInteger s=NSProcessInfo.processInfo.thermalState;
    out[@(labels[Thermal])]=s>=0&&s<=3?@[@"Nominal",@"Fair",@"Serious",@"Critical"][s]:@"Unavailable";
  }
  return out;
}

// macOS 27+: Apple's HUD shows these under State Reporters, sorted by label.
//
// SRStateReporter is resolved at runtime rather than linked, so this builds
// against an SDK that predates StateReporting.framework -- Xcode 26 has no such
// framework, public or private, and -weak_framework cannot weak-link something
// the SDK does not describe. The macOS 26 path below already works this way;
// this just makes both paths consistent.
void reportModern(NSDictionary *values) {
  static bool live=false;
  static Class cls=objc_lookUpClass("SRStateReporter");
  if(!cls) return;

  static SEL forDomain=@selector(reporterForDomain:);
  if(![cls respondsToSelector:forDomain]) return;
  id reporter=((id(*)(Class,SEL,id))objc_msgSend)(cls,forDomain,@(kDomain));
  if(!reporter) return;

  SEL transition=@selector(reportTransitionToStateLabel:stableMetadata:volatileMetadata:);
  SEL update=@selector(reportVolatileMetadataUpdate:);
  if(![reporter respondsToSelector:transition]||![reporter respondsToSelector:update]) return;

  if(!values.count) {
    if(live) ((void(*)(id,SEL,id,id,id))objc_msgSend)(reporter,transition,nil,nil,nil);
    live=false;
    return;
  }
  if(!live) ((void(*)(id,SEL,id,id,id))objc_msgSend)(reporter,transition,@"Live",nil,values);
  else      ((void(*)(id,SEL,id))objc_msgSend)(reporter,update,values);
  live=true;
}

// macOS 26: one HUD line per stat via _CADeveloperHUDProperties (addLabel:after:, updateLabel:value:, remove:),
// the same calls DXMT makes. These methods are gone on 27, so every call is guarded.
// ponytail: untested on a macOS 26 machine; verify layout and threading there.
void reportLegacy(NSDictionary<NSString*,NSString*> *values) {
  static NSArray<NSString*> *shown=@[];
  id hud=nil;
  if(Class cls=objc_lookUpClass("_CADeveloperHUDProperties"); cls && [cls respondsToSelector:@selector(instance)])
    hud=((id(*)(id,SEL))objc_msgSend)(cls,@selector(instance));
  if(!hud||![hud respondsToSelector:@selector(addLabel:after:)]||![hud respondsToSelector:@selector(updateLabel:value:)]||![hud respondsToSelector:@selector(remove:)]) return;
  // Group by subsystem rather than alphabetically. Sorting by label scatters
  // related rows -- "E-core power" lands between "Disk write" and "Ethernet
  // down" -- which makes a long list hard to read. labels[] is already in a
  // sensible order, so rank by that and fall back to alphabetical for anything
  // not in the table (the per-fan rows, which are generated).
  NSArray *keys=[values.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){
    auto rank=[](NSString *label)->NSInteger{
      for(NSInteger i=0;i<MetricCount;i++)
        if([label isEqualToString:@(labels[i])]) return i;
      // Fan rows sit with Fans; everything unknown goes last.
      if([label hasPrefix:@"Fan "]) return Fans;
      // Combined rows rank where their first component would.
      if([label isEqualToString:@"Disk R/W"]) return DiskRead;
      if([label isEqualToString:@"Ext disk R/W"]) return ExtDiskRead;
      if([label isEqualToString:@"Network D/U"]) return NetDown;
      if([label isEqualToString:@"Wi-Fi D/U"]) return WifiDown;
      if([label isEqualToString:@"Ethernet D/U"]) return EthDown;
      return MetricCount;
    };
    NSInteger ra=rank(a), rb=rank(b);
    if(ra!=rb) return ra<rb?NSOrderedAscending:NSOrderedDescending;
    return [a compare:b];
  }];
  NSMutableArray *ids=[NSMutableArray array];
  for(NSString *key in keys) [ids addObject:[@"MetalHUDmenu." stringByAppendingString:key]];
  if(![ids isEqualToArray:shown]) {
    for(NSString *label in shown) ((void(*)(id,SEL,id))objc_msgSend)(hud,@selector(remove:),label);
    NSString *after=@"com.apple.hud-graph.default";
    for(NSString *label in ids) { ((BOOL(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(addLabel:after:),label,after); after=label; }
    shown=ids;
  }
  // The HUD right-aligns only the value (the unit), so the number lives in the
  // left-hand text and lands wherever the label name ends. Padding every name
  // to the widest in the current set puts all the numbers in one column; the
  // HUD font is monospace, so spaces are exact.
  NSUInteger widest=0;
  for(NSString *key in keys) widest=MAX(widest,key.length);
  for(NSUInteger i=0;i<keys.count;i++) {
    NSString *padded=[keys[i] stringByPaddingToLength:widest withString:@" " startingAtIndex:0];
    ((void(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(updateLabel:value:),ids[i],
      [NSString stringWithFormat:@"%@  %@",padded,values[keys[i]]]);
  }
}

void tick() { @autoreleasepool {
  bool on[MetricCount]; readSelection(on);
  NSDictionary *values=sample(on);
  if(@available(macOS 27.0,*)) reportModern(values); else reportLegacy(values);
  if(debug) fprintf(stderr,"MHUD_STATS %s\n",values.description.UTF8String);
} }

// Runs under dyld's loader lock: only look up the image name, then start the timer.
void imageAdded(const mach_header *header,intptr_t) {
  const char *name=nullptr;
  for(uint32_t i=0,n=_dyld_image_count();i<n;i++) if(_dyld_get_image_header(i)==header) { name=_dyld_get_image_name(i); break; }
  if(!name) return;
  const char *base=strrchr(name,'/'); base=base?base+1:name;
  if(strcmp(base,"libMTLHud.dylib")!=0||started.test_and_set()) return;
  timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_queue_create("MetalHUDmenu.stats",DISPATCH_QUEUE_SERIAL));
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
  dispatch_source_set_event_handler(timer,^{ tick(); });
  dispatch_resume(timer);
  if(debug) fprintf(stderr,"MHUD_STATS_STARTED %s\n",name);
}

// Append a token to a comma-separated env var unless it is already there.
void appendEnv(const char *key,const char *token) {
  const char *cur=getenv(key);
  if(!cur||!*cur) { setenv(key,token,1); return; }
  std::string list=std::string(",")+cur+",";
  if(list.find(std::string(",")+token+",")!=std::string::npos) return;
  setenv(key,(std::string(cur)+","+token).c_str(),1);
}
} // namespace

__attribute__((constructor)) static void start() {
  debug=getenv("MHUD_DEBUG")&&!strcmp(getenv("MHUD_DEBUG"),"1");
  // Adds the State Reporters section on top of the user's own HUD rows (read when Apple's HUD loads).
  if(@available(macOS 27.0,*)) {
    appendEnv("MTL_HUD_EXTRA_ELEMENTS","statereporter");
    appendEnv("MTL_HUD_STATE_REPORTER_DOMAINS",kDomain);
  }
  _dyld_register_func_for_add_image(imageAdded);
}
