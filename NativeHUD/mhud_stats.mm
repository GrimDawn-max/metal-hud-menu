// MetalHUDmenu Mac stats: live system readings inside Apple's Metal HUD.
// macOS 27+: public StateReporting API. macOS 26: Apple's custom-metric API (Custom Metrics section)
// where the HUD has it, otherwise the private QuartzCore label API DXMT uses.
// The stat selection is read live from MetalHUDmenu's preferences (key "systemStats").
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <os/log.h>
#include <dlfcn.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include "stats/telemetry.hpp"
#include "stats/power.hpp"
#include "stats/io.hpp"
#include "stats/usage.hpp"

namespace {
// Diagnostics through os_log, not stderr.
//
// A game started by LaunchServices has nowhere for stderr to go, so MHUD_DEBUG
// said nothing about the one case that matters. These lines are readable
// whatever starts the process:
//
//   log stream --style compact --predicate 'subsystem == "local.mhudstats"'
//
// Lifecycle only -- a handful of lines per process, not per frame.
os_log_t mlog() {
  static os_log_t l=os_log_create("local.mhudstats","diag");
  return l;
}
#define MHUD_LOG(fmt,...) os_log(mlog(),fmt,##__VA_ARGS__)

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
  // Logged once: an empty selection yields no rows and looks identical to a
  // dylib that never ran.
  static bool told=false;
  if(!told) {
    told=true;
    int n=0; for(int i=0;i<MetricCount;i++) if(enabled[i]) n++;
    MHUD_LOG("selection: %d of %d metrics, from %{public}s, list had %lu entries",
             n, (int)MetricCount,
             getenv("MHUD_SYSTEM_ELEMENTS") ? "the environment" : "preferences",
             (unsigned long)list.count);
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

// Keeping our rows when another writer takes them away.
//
// A translated DX12 game runs Apple's D3DMetal (x86_64 only), which drives
// this same private HUD API: it carries `_CADeveloperHUDProperties`,
// `addLabel:after:`, `updateLabel:value:`, `remove:` and the same
// `com.apple.hud-graph.default` anchor used here. It is present in exactly the
// process where these rows disappear and absent from a native app, where they
// survive -- and it is the only writer found that *removes* labels.
//
// So refuse to let our own ids be removed, and say who tried. Only ids with
// our prefix are protected: another writer's own rows are passed straight
// through, so nothing it manages is affected.
NSString *const kLabelPrefix=@"MetalHUDmenu.";

const char *callerImage(void *addr) {
  Dl_info info;
  if(dladdr(addr,&info)&&info.dli_fname) {
    const char *b=strrchr(info.dli_fname,'/');
    return b?b+1:info.dli_fname;
  }
  return "(unknown)";
}

void (*origRemove)(id,SEL,id)=nullptr;
BOOL (*origAddLabel)(id,SEL,id,id)=nullptr;

void removeHook(id self,SEL sel,id label) {
  if([label isKindOfClass:NSString.class]&&[(NSString*)label hasPrefix:kLabelPrefix]) {
    static bool told=false;
    if(!told) {
      told=true;
      MHUD_LOG("hook: %{public}s tried to remove %{public}s -- refused",
               callerImage(__builtin_return_address(0)),[(NSString*)label UTF8String]);
    }
    return;
  }
  if(origRemove) origRemove(self,sel,label);
}

// Not a fix, a witness: whether anything else adds rows in this process
// settles whether added labels render here at all.
BOOL addLabelHook(id self,SEL sel,id label,id after) {
  if(!([label isKindOfClass:NSString.class]&&[(NSString*)label hasPrefix:kLabelPrefix])) {
    static const char *seen=nullptr;
    const char *who=callerImage(__builtin_return_address(0));
    if(!seen||strcmp(seen,who)) {
      seen=who;
      MHUD_LOG("hook: %{public}s adds its own row %{public}s",
               who,[label isKindOfClass:NSString.class]?[(NSString*)label UTF8String]:"(not a string)");
    }
  }
  return origAddLabel?origAddLabel(self,sel,label,after):NO;
}

// Called from every tick, not once at startup: the class is created as part of
// Apple's HUD setup, which happens after the add-image callback that starts
// the timer, so a single attempt there always finds it absent.
void installLabelHooks() {
  if(origRemove) return;
  Class cls=objc_lookUpClass("_CADeveloperHUDProperties");
  if(!cls) return;
  // The return type is spelled differently per architecture -- BOOL is "B" on
  // arm64 and "c" (signed char) on x86_64 -- so match the accepted return
  // characters and the argument list separately. Comparing the whole encoding
  // silently disabled the hook in translated processes, the one place it is
  // needed.
  struct { const char *sel; void **slot; IMP repl; const char *rets; const char *args; } want[]={
    {"remove:",        (void**)&origRemove,   (IMP)removeHook,   "v",  "24@0:8@16"},
    {"addLabel:after:",(void**)&origAddLabel, (IMP)addLabelHook, "Bc", "32@0:8@16@24"},
  };
  for(auto &w:want) {
    Method m=class_getInstanceMethod(cls,sel_registerName(w.sel));
    if(!m) { MHUD_LOG("hook: %{public}s not found", w.sel); continue; }
    // The return type is not documented. A BOOL-returning replacement is safe
    // over a void original (the caller ignores the register); the reverse is
    // not, so bail on anything unexpected rather than guess.
    // Measured: remove: is v24@0:8@16, addLabel:after: is B32@0:8@16@24.
    // Anything else is a different method than the one these hooks match, so
    // leave it alone rather than call through a wrong signature.
    const char *enc=method_getTypeEncoding(m);
    if(!enc||!strchr(w.rets,enc[0])||strcmp(enc+1,w.args)) {
      MHUD_LOG("hook: %{public}s signature is %{public}s, expected [%{public}s]%{public}s -- left alone",
               w.sel, enc?:"(none)", w.rets, w.args);
      continue;
    }
    *w.slot=(void*)method_getImplementation(m);
    method_setImplementation(m,w.repl);
    MHUD_LOG("hook: %{public}s installed (signature %{public}s)", w.sel, enc?:"?");
  }
}

NSArray<NSString*> *orderedKeys(NSDictionary<NSString*,NSString*> *values);

// macOS 26: one HUD line per stat via _CADeveloperHUDProperties (addLabel:after:, updateLabel:value:, remove:),
// the same calls DXMT makes. These methods are gone on 27, so every call is guarded.
// ponytail: untested on a macOS 26 machine; verify layout and threading there.
void reportLegacy(NSDictionary<NSString*,NSString*> *values) {
  static NSArray<NSString*> *shown=@[];
  // A process can build the HUD more than once -- a game launcher draws with
  // Metal before the game's own layer exists, and the second HUD knows nothing
  // of the labels added to the first. updateLabel: on a label the current HUD
  // has never seen does nothing and reports nothing, so caching the added set
  // forever means the rows vanish the moment the HUD is rebuilt. Re-adding
  // every few seconds costs nothing and survives that.
  static unsigned long reports=0;
  if(++reports%5==0) shown=@[];
  id hud=nil;
  static bool toldHud=false;
  if(!toldHud) {
    toldHud=true;
    Class probe=objc_lookUpClass("_CADeveloperHUDProperties");
    MHUD_LOG("legacy path: _CADeveloperHUDProperties %{public}s, responds to instance: %{public}s",
             probe ? "found" : "MISSING",
             (probe && [probe respondsToSelector:@selector(instance)]) ? "yes" : "no");
  }
  if(Class cls=objc_lookUpClass("_CADeveloperHUDProperties"); cls && [cls respondsToSelector:@selector(instance)])
    hud=((id(*)(id,SEL))objc_msgSend)(cls,@selector(instance));
  static bool toldInstance=false;
  if(!toldInstance) {
    toldInstance=true;
    MHUD_LOG("legacy path: instance %{public}s, addLabel:after: %{public}s, updateLabel:value: %{public}s, remove: %{public}s",
             hud ? object_getClassName(hud) : "nil",
             (hud && [hud respondsToSelector:@selector(addLabel:after:)]) ? "yes" : "no",
             (hud && [hud respondsToSelector:@selector(updateLabel:value:)]) ? "yes" : "no",
             (hud && [hud respondsToSelector:@selector(remove:)]) ? "yes" : "no");
  }
  if(!hud||![hud respondsToSelector:@selector(addLabel:after:)]||![hud respondsToSelector:@selector(updateLabel:value:)]||![hud respondsToSelector:@selector(remove:)]) return;
  NSArray *keys=orderedKeys(values);
  NSMutableArray *ids=[NSMutableArray array];
  for(NSString *key in keys) [ids addObject:[@"MetalHUDmenu." stringByAppendingString:key]];
  if(![ids isEqualToArray:shown]) {
    for(NSString *label in shown) ((void(*)(id,SEL,id))objc_msgSend)(hud,@selector(remove:),label);
    NSString *after=@"com.apple.hud-graph.default";
    NSUInteger yes=0,no=0; NSString *firstNo=nil;
    for(NSString *label in ids) {
      BOOL ok=((BOOL(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(addLabel:after:),label,after);
      if(!ok) {
        // The anchor row may not exist in this process (a translated game's HUD
        // carries a different set), so the insert is refused. Retry unanchored.
        ok=((BOOL(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(addLabel:after:),label,(id)nil);
      }
      if(ok) yes++; else { no++; if(!firstNo) firstNo=label; }
      after=label;
    }
    MHUD_LOG("legacy path: report %lu, addLabel accepted %lu, refused %lu%{public}s",
             reports,(unsigned long)yes,(unsigned long)no,
             firstNo ? [[@", first refused: " stringByAppendingString:firstNo] UTF8String] : "");
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

// Group by subsystem rather than alphabetically. Sorting by label scatters
// related rows -- "E-core power" lands between "Disk write" and "Ethernet
// down" -- which makes a long list hard to read. labels[] is already in a
// sensible order, so rank by that and fall back to alphabetical for anything
// not in the table (the per-fan rows, which are generated).
NSArray<NSString*> *orderedKeys(NSDictionary<NSString*,NSString*> *values) {
  return [values.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){
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
}

// macOS 26: Apple's custom-metric API, the one D3DMetal uses for its own section. Rows appear under
// "Custom Metrics" and, unlike added labels, are shown while MTL_HUD_ELEMENTS is set, so the user's
// element picks are kept. On macOS 26.4 the methods are on _CADeveloperHUDProperties; MTLHUDService
// is the name later builds use.
//
// The section only draws when the HUD's "client" element (bit 31) was on when the HUD read its
// settings, which happens once, when the HUD is created -- normally at the process's first Metal
// frame. A helper loaded after that (through a Wine runtime's winemac.so, in Grim Dawn) cannot add
// it, so MetalHUDmenu puts MTL_HUD_EXTRA_ELEMENTS=client into the environment games inherit.
// Measured on macOS 26.4.1.
//
// Returns nil until the HUD exists, NO when this API cannot be used (fall back to labels).
NSNumber *reportCustom(NSDictionary<NSString*,NSString*> *values) {
  Class cls=objc_lookUpClass("MTLHUDService")?:objc_lookUpClass("_CADeveloperHUDProperties");
  if(!cls||![cls respondsToSelector:@selector(instance)]) return @NO;
  SEL insert=@selector(insertMetric:after:name:unit:nameColor:valueColor:visualType:options:);
  Method m=class_getInstanceMethod(cls,insert);
  // BOOL is "B" on arm64 and "c" on x86_64; the arguments must match exactly.
  if(!m||strcmp(method_getTypeEncoding(m)+1,"68@0:8@16@24@32@40I48I52I56Q60")) return @NO;
  for(SEL s:{@selector(updateLabelMetric:label:),@selector(removeMetric:),@selector(isHUDElementEnabled:)})
    if(![cls instancesRespondToSelector:s]) return @NO;
  id hud=((id(*)(id,SEL))objc_msgSend)(cls,@selector(instance));
  if(!hud) return nil;
  if(!((BOOL(*)(id,SEL,uint64_t))objc_msgSend)(hud,@selector(isHUDElementEnabled:),1ull<<31)) {
    static bool told=false;
    if(!told) { told=true; MHUD_LOG("custom metrics: the HUD's client element is off -- falling back to labels"); }
    return @NO;
  }
  // A rebuilt HUD is a new instance that knows nothing of the rows added to the old one.
  static __weak id lastHud=nil;
  static NSArray<NSString*> *shown=@[];
  if(hud!=lastHud) { lastHud=hud; shown=@[]; }
  NSArray<NSString*> *keys=orderedKeys(values);
  NSMutableArray *ids=[NSMutableArray array];
  for(NSString *key in keys) [ids addObject:[kLabelPrefix stringByAppendingString:key]];
  if(![ids isEqualToArray:shown]) {
    for(NSString *row in shown) ((void(*)(id,SEL,id))objc_msgSend)(hud,@selector(removeMetric:),row);
    for(NSUInteger i=0;i<keys.count;i++) // nil "after" appends
      ((BOOL(*)(id,SEL,id,id,id,id,uint32_t,uint32_t,uint32_t,uint64_t))objc_msgSend)(hud,insert,
        ids[i],nil,keys[i],@"",0xFFFFFFFFu,0xFFFFFFFFu,1u,0ull);
    MHUD_LOG("custom metrics: %lu rows",(unsigned long)ids.count);
    shown=ids;
  }
  for(NSUInteger i=0;i<keys.count;i++)
    ((void(*)(id,SEL,id,id))objc_msgSend)(hud,@selector(updateLabelMetric:label:),ids[i],values[keys[i]]);
  return @YES;
}

void tick() { @autoreleasepool {
  static unsigned long ticks=0;
  if(++ticks==1||ticks%60==0) MHUD_LOG("tick %lu", ticks);
  installLabelHooks();
  bool on[MetricCount]; readSelection(on);
  NSDictionary *values=sample(on);
  if(@available(macOS 27.0,*)) { reportModern(values); return; }
  // Decided once the HUD exists; labels only when custom metrics cannot be used here.
  static int route=0; // 0 undecided, 1 custom metrics, 2 labels
  if(route!=2) {
    NSNumber *ok=reportCustom(values);
    if(!ok) return;
    if(!route) {
      route=ok.boolValue?1:2;
      MHUD_LOG("reporting via the macOS 26 %{public}s path",route==1?"custom-metrics":"label");
    }
    if(route==1) return;
  }
  reportLegacy(values);
  if(debug) fprintf(stderr,"MHUD_STATS %s\n",values.description.UTF8String);
} }

// Runs under dyld's loader lock: only look up the image name, then start the timer.
void imageAdded(const mach_header *header,intptr_t) {
  const char *name=nullptr;
  for(uint32_t i=0,n=_dyld_image_count();i<n;i++) if(_dyld_get_image_header(i)==header) { name=_dyld_get_image_name(i); break; }
  if(!name) return;
  const char *base=strrchr(name,'/'); base=base?base+1:name;
  if(strstr(base,"MTLHud")||strstr(base,"MTLHUD"))
    MHUD_LOG("image seen: %{public}s", name);
  if(strcmp(base,"libMTLHud.dylib")!=0||started.test_and_set()) return;
  timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_queue_create("MetalHUDmenu.stats",DISPATCH_QUEUE_SERIAL));
  dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,NSEC_PER_SEC/10);
  dispatch_source_set_event_handler(timer,^{ tick(); });
  dispatch_resume(timer);
  if(debug) fprintf(stderr,"MHUD_STATS_STARTED %s\n",name);
  MHUD_LOG("timer started on %{public}s", name);
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
  { char exe[4096]; uint32_t sz=sizeof exe; if(_NSGetExecutablePath(exe,&sz)!=0) strcpy(exe,"?");
    MHUD_LOG("constructor: pid %d, exe %{public}s, images %u, MHUD_SYSTEM_ELEMENTS=%{public}s",
             getpid(), exe, _dyld_image_count(),
             getenv("MHUD_SYSTEM_ELEMENTS") ?: "(unset)"); }
  // MTL_HUD_ELEMENTS is an allow-list of element names, and rows added through
  // addLabel:after: are not in it under any spelling -- adding our own ids, or
  // "user", or MTL_HUD_EXTRA_ELEMENTS, all still render nothing. While it is
  // set, Apple's HUD draws its own stats and silently drops every added label.
  //
  // It only matters for a game started by LaunchServices: the HUD's own panel
  // writes it into the launchd session, so a terminal-launched app usually
  // does not have it, which is why this went unnoticed for so long. Clearing
  // it here works because this constructor runs when the dylib is inserted,
  // and Apple's HUD reads the variable later, when it is created at the first frame.
  //
  // The default element set is very close to what the panel writes anyway, so
  // little is lost; the alternative is custom rows that never appear.
  //
  // None of this applies where the custom-metric API exists (macOS 26.4 has it): its rows are shown
  // with MTL_HUD_ELEMENTS set, so the picks stay and only "client" is added. That works here when this
  // constructor runs before the HUD is created; MetalHUDmenu also sets it for later loads.
  // The HUD library may not be loaded yet, so look for the method in the file. macOS 27 keeps its own path.
  bool customMetrics=false;
  if(@available(macOS 27.0,*)) {}
  else for(const char *path:{"/usr/lib/libMTLHud.dylib","/System/Volumes/Preboot/Cryptexes/OS/usr/lib/libMTLHud.dylib"}) {
    NSData *data=[NSData dataWithContentsOfFile:@(path) options:NSDataReadingMappedIfSafe error:nil];
    const char *needle="insertMetric:after:name:unit:nameColor:valueColor:visualType:options:";
    if(data&&memmem(data.bytes,data.length,needle,strlen(needle))) { customMetrics=true; break; }
  }
  if(customMetrics) appendEnv("MTL_HUD_EXTRA_ELEMENTS","client");
  if(const char *el=getenv("MTL_HUD_ELEMENTS"); el&&!customMetrics) {
    MHUD_LOG("clearing MTL_HUD_ELEMENTS (%{public}s) -- it hides every added row", el);
    unsetenv("MTL_HUD_ELEMENTS");
  }
  // Adds the State Reporters section on top of the user's own HUD rows (read when Apple's HUD loads).
  if(@available(macOS 27.0,*)) {
    appendEnv("MTL_HUD_EXTRA_ELEMENTS","statereporter");
    appendEnv("MTL_HUD_STATE_REPORTER_DOMAINS",kDomain);
  }
  _dyld_register_func_for_add_image(imageAdded);
  MHUD_LOG("constructor: add-image callback registered");
}
