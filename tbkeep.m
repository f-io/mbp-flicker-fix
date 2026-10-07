#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <ctype.h>
#import <dlfcn.h>
#import <math.h>
#import <sys/sysctl.h>

#define TBKEEP_VERSION "1.0.0"

@interface BrightnessSystemClient : NSObject
- (id)copyPropertyForKey:(id)key;
- (id)copyPropertyForKey:(id)key andDisplay:(unsigned long long)display;
- (BOOL)setProperty:(id)value withKey:(id)key andDisplay:(unsigned long long)display;
- (BOOL)activateWithError:(NSError **)error;
- (void)registerDisplayNotificationCallbackBlock:(void (^)(id key, unsigned long long display, id value))block;
- (void)registerNotificationForKeys:(id)keys andDisplay:(unsigned long long)display;
@end

@interface DFRBrightnessClient : NSObject
- (int)getDFRDisplayID;
- (long long)getDimmingStep;
- (void)flushPropertyCache;
- (BOOL)initializeHID;
- (void)scheduleWithDispatchQueue:(dispatch_queue_t)queue;
- (BOOL)dimToStep:(long long)step withPeriod:(float)period;
- (BOOL)dimToStep:(long long)step withPeriod:(float)period andCoefficient:(float)coefficient;
@end

static NSString *const kAgentLabel = @"local.tbkeep";
static const int kTypeTouchBar = 3;
static const long long kStepNormal = 1;
static const long long kStepDim = 2;
static const long long kStepOff = 4;
static const double kLuxToRelease = 1.5;
static const double kDefaultLevel = 0.40;
static const NSTimeInterval kStepPoll = 0.02;
static const NSTimeInterval kIdleBeforePolling = 1.0;

#pragma mark - Settings and log

static NSString *SupportDir(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/tbkeep"];
}

static NSString *ReadSetting(NSString *name) {
  NSString *path = [SupportDir() stringByAppendingPathComponent:name];
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static BOOL WriteSetting(NSString *name, NSString *value) {
  [NSFileManager.defaultManager createDirectoryAtPath:SupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [SupportDir() stringByAppendingPathComponent:name];
  return [[value stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// The saved level (0.05-1.0), or NAN when the fix is disabled (stored as "auto").
static double SavedLevel(void) {
  NSString *text = ReadSetting(@"level");
  if (text.length == 0) return kDefaultLevel;
  if ([text isEqualToString:@"auto"]) return NAN;
  double level = text.doubleValue;
  return (level >= 0.05 && level <= 1.0) ? level : kDefaultLevel;
}

static void Log(NSString *format, ...) {
  static NSDate *hourStart;
  static int linesThisHour;
  NSDate *now = NSDate.date;
  if (!hourStart || [now timeIntervalSinceDate:hourStart] > 3600) {
    hourStart = now;
    linesThisHour = 0;
  }
  if (++linesThisHour > 120) return;
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  NSDateFormatter *formatter = [NSDateFormatter new];
  formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
  fprintf(stderr, "%s %s\n", [formatter stringFromDate:now].UTF8String, message.UTF8String);
  fflush(stderr);
}

#pragma mark - Apple's brightness services

static BOOL OpenFramework(NSString *name) {
  NSString *base = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework", name];
  return dlopen([base stringByAppendingFormat:@"/Versions/A/%@", name].UTF8String, RTLD_NOW) ||
         dlopen([base stringByAppendingFormat:@"/%@", name].UTF8String, RTLD_NOW);
}

static NSString *MissingAPI(void) {
  if (!OpenFramework(@"CoreBrightness")) return @"Apple's CoreBrightness framework was not found";
  if (!OpenFramework(@"DFRBrightness")) return @"Apple's Touch Bar brightness framework was not found";
  Class brightness = NSClassFromString(@"BrightnessSystemClient");
  Class dimming = NSClassFromString(@"DFRBrightnessClient");
  if (!brightness || !dimming) return @"Apple's brightness classes were not found";
  for (NSString *selector in @[ @"copyPropertyForKey:", @"copyPropertyForKey:andDisplay:", @"setProperty:withKey:andDisplay:" ])
    if (![brightness instancesRespondToSelector:NSSelectorFromString(selector)])
      return [NSString stringWithFormat:@"BrightnessSystemClient has no %@", selector];
  for (NSString *selector in @[ @"initializeHID", @"scheduleWithDispatchQueue:", @"getDimmingStep", @"dimToStep:withPeriod:",
                                 @"dimToStep:withPeriod:andCoefficient:" ])
    if (![dimming instancesRespondToSelector:NSSelectorFromString(selector)])
      return [NSString stringWithFormat:@"DFRBrightnessClient has no %@", selector];
  return nil;
}

static BOOL ReportsTouchBarType(BrightnessSystemClient *brightness, long long display, BOOL requireType) {
  id type = [brightness copyPropertyForKey:@"CBDisplayType" andDisplay:display];
  if (![type isKindOfClass:NSNumber.class]) return !requireType;
  return [type intValue] == kTypeTouchBar;
}

static long long TouchBarDisplay(BrightnessSystemClient *brightness, DFRBrightnessClient *dimming) {
  if (!brightness) return -1;
  if ([dimming respondsToSelector:@selector(getDFRDisplayID)]) {
    int display = [dimming getDFRDisplayID];
    if (display > 0 && ReportsTouchBarType(brightness, display, NO)) return display;
  }
  id list = [brightness copyPropertyForKey:@"CBDisplayList"];
  if (![list isKindOfClass:NSDictionary.class]) return -1;
  for (NSNumber *display in list[@"CBDisplayDeviceIDs"])
    if ([display isKindOfClass:NSNumber.class] && ReportsTouchBarType(brightness, display.longLongValue, YES))
      return display.longLongValue;
  return -1;
}

static double CurrentLevel(BrightnessSystemClient *brightness, long long display, BOOL *autoOn, double *nits) {
  id autoValue = [brightness copyPropertyForKey:@"DisplayBrightnessAuto" andDisplay:display];
  id value = [brightness copyPropertyForKey:@"DisplayBrightness" andDisplay:display];
  if (autoOn) *autoOn = [autoValue isKindOfClass:NSNumber.class] && [autoValue boolValue];
  if (![value isKindOfClass:NSDictionary.class]) return NAN;
  if (nits) *nits = [value[@"Nits"] doubleValue];
  return [value[@"Brightness"] doubleValue];
}

static BOOL ApplyLevel(BrightnessSystemClient *brightness, long long display, double level) {
  BOOL autoOff = [brightness setProperty:@NO withKey:@"DisplayBrightnessAuto" andDisplay:display];
  BOOL levelSet = [brightness setProperty:@{@"Brightness" : @(level)} withKey:@"DisplayBrightness" andDisplay:display];
  return autoOff && levelSet;
}

static BOOL ApplyAuto(BrightnessSystemClient *brightness, long long display) {
  return [brightness setProperty:@YES withKey:@"DisplayBrightnessAuto" andDisplay:display];
}

static double AmbientLux(BrightnessSystemClient *brightness) {
  id lux = [brightness copyPropertyForKey:@"Lux"];
  return [lux isKindOfClass:NSNumber.class] ? [lux doubleValue] : NAN;
}

#pragma mark - Background mode

@interface Keeper : NSObject
@property(strong) BrightnessSystemClient *brightness;
@property(strong) DFRBrightnessClient *dimming;
@property long long display;
@property double level;
@property double appliedLevel;
@property double minimumNits;
@property double lastNits;
@property BOOL holding;
@property double holdLux;
@property long long watchedDisplay;
@property long long lastStep;
@property NSUInteger checksWithoutTouchBar;
@property(strong) NSTimer *stepTimer;
@end

@implementation Keeper

- (void)connect {
  self.brightness = [[NSClassFromString(@"BrightnessSystemClient") alloc] init];
  self.watchedDisplay = -1;
  if ([self.brightness respondsToSelector:@selector(registerDisplayNotificationCallbackBlock:)] &&
      [self.brightness respondsToSelector:@selector(activateWithError:)]) {
    __weak Keeper *weakSelf = self;
    [self.brightness registerDisplayNotificationCallbackBlock:^(id key, unsigned long long display, id value) {
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf brightnessChanged:key display:display value:value]; });
    }];
    [self.brightness activateWithError:nil];
  }
  self.dimming = [[NSClassFromString(@"DFRBrightnessClient") alloc] init];
  [self.dimming initializeHID];
  [self.dimming scheduleWithDispatchQueue:dispatch_get_main_queue()];
}

// Auto-brightness runs freely above the minimum. When it goes below, tbkeep holds the minimum
// until the room gets clearly brighter, so the two do not hand control back and forth.
- (void)holdMinimum:(NSString *)reason {
  self.holding = YES;
  self.holdLux = AmbientLux(self.brightness);
  ApplyLevel(self.brightness, self.display, self.level);
  Log(@"holding the minimum of %.0f%% (%@, %.0f lux)", self.level * 100, reason, self.holdLux);
}

- (void)reapplyMinimum:(double)current autoOn:(BOOL)autoOn {
  ApplyLevel(self.brightness, self.display, self.level);
  Log(@"minimum of %.0f%% re-applied (it was %@)", self.level * 100,
      autoOn ? @"on auto" : (isnan(current) ? @"unknown" : [NSString stringWithFormat:@"%.0f%%", current * 100]));
}

- (void)releaseMinimum {
  self.holding = NO;
  ApplyAuto(self.brightness, self.display);
  Log(@"auto-brightness above the minimum (%.0f lux)", AmbientLux(self.brightness));
}

- (void)checkNits:(double)nits brightness:(double)brightness autoOn:(BOOL)autoOn {
  if (isnan(self.level) || isnan(nits)) return;
  // Brightness jumps to the target at once while Nits still fades there, so only a settled value counts.
  BOOL settled = fabs(nits - self.lastNits) < 0.5;
  if (!autoOn && fabs(brightness - self.level) < 0.005 && settled && !(fabs(nits - self.minimumNits) < 0.5)) {
    self.minimumNits = nits;
    Log(@"minimum of %.0f%% is %.0f nits", self.level * 100, nits);
  }
  self.lastNits = nits;
  if (!self.holding && autoOn && !isnan(self.minimumNits) && nits < self.minimumNits - 1)
    [self holdMinimum:[NSString stringWithFormat:@"auto went to %.0f nits", nits]];
}

- (void)brightnessChanged:(id)key display:(unsigned long long)display value:(id)value {
  if ((long long)display != self.display || ![key isEqual:@"DisplayBrightness"] || ![value isKindOfClass:NSDictionary.class]) return;
  BOOL autoOn = NO;
  CurrentLevel(self.brightness, self.display, &autoOn, NULL);
  [self checkNits:[value[@"Nits"] doubleValue] brightness:[value[@"Brightness"] doubleValue] autoOn:autoOn];
}

- (void)enforce:(NSString *)reason {
  self.level = SavedLevel();
  self.display = TouchBarDisplay(self.brightness, self.dimming);
  if (self.display < 0) {  // the brightness service may have restarted
    [self connect];
    self.display = TouchBarDisplay(self.brightness, self.dimming);
  }
  if (self.display < 0) {
    if (++self.checksWithoutTouchBar == 30) Log(@"no Touch Bar display found yet; still checking");
    return;
  }
  self.checksWithoutTouchBar = 0;
  if (self.display != self.watchedDisplay && [self.brightness respondsToSelector:@selector(registerNotificationForKeys:andDisplay:)]) {
    [self.brightness registerNotificationForKeys:@[ @"DisplayBrightness" ] andDisplay:self.display];
    self.watchedDisplay = self.display;
  }

  BOOL autoOn = NO;
  double nits = NAN;
  double current = CurrentLevel(self.brightness, self.display, &autoOn, &nits);
  if (isnan(self.level)) {
    self.holding = NO;
    self.appliedLevel = NAN;
    if (!autoOn && ApplyAuto(self.brightness, self.display)) Log(@"disabled: macOS controls the Touch Bar (%@)", reason);
    return;
  }
  if (self.level != self.appliedLevel) {
    self.appliedLevel = self.level;
    self.minimumNits = NAN;
    [self holdMinimum:[NSString stringWithFormat:@"%@, new minimum", reason]];
    return;
  }
  if (self.resting) {
    if (autoOn || isnan(current) || fabs(current - self.level) > 0.02) [self reapplyMinimum:current autoOn:autoOn];
    else [self checkNits:nits brightness:current autoOn:autoOn];
    return;
  }
  if (self.holding) {
    if (autoOn || isnan(current) || fabs(current - self.level) > 0.02) [self reapplyMinimum:current autoOn:autoOn];
    double lux = AmbientLux(self.brightness);
    if (!isnan(self.minimumNits) && !isnan(lux) && lux > self.holdLux * kLuxToRelease && lux > self.holdLux + 5)
      [self releaseMinimum];
    else
      [self checkNits:nits brightness:current autoOn:autoOn];
    return;
  }
  if (!autoOn) ApplyAuto(self.brightness, self.display);
  else [self checkNits:nits brightness:current autoOn:autoOn];
}

- (BOOL)resting {
  return self.lastStep == kStepDim || self.lastStep == kStepOff;
}

// Dim and off both show the minimum: CoreBrightness jumps there at once, and the dim step runs with
// coefficient 1, so it changes nothing. The bar never really switches off, because a worn panel
// flickers when switched off too. With nothing to show it is black, and black OLED pixels stay dark.
// A dim factor would follow auto-brightness below the minimum.
// The service ignores the step it is already fading to, so a detour is needed to cut that fade.
- (void)followStep {
  if ([self.dimming respondsToSelector:@selector(flushPropertyCache)]) [self.dimming flushPropertyCache];
  long long step = [self.dimming getDimmingStep];
  if (step == 0 || step == self.lastStep) return;
  BOOL wasResting = self.resting;
  if (step == kStepNormal) {
    [self.dimming dimToStep:kStepDim withPeriod:0 andCoefficient:1];
    [self.dimming dimToStep:kStepNormal withPeriod:0];
    self.lastStep = step;
    if (wasResting && !self.holding && !isnan(self.level)) ApplyAuto(self.brightness, self.display);
    if (wasResting) Log(@"Touch Bar woke");
    return;
  }
  if (!wasResting && !isnan(self.level)) ApplyLevel(self.brightness, self.display, self.level);
  [self.dimming dimToStep:kStepNormal withPeriod:0];
  [self.dimming dimToStep:kStepDim withPeriod:0 andCoefficient:1];
  Log(step == kStepDim ? @"Touch Bar dimmed to the minimum at once" : @"Touch Bar kept at the minimum instead of switching off, showing black");
  self.lastStep = step;
}

// No event announces a dim or an off, so the step is polled, but only once input has paused. Once macOS
// has switched the bar off, nothing can fade any more, and the 2 s check is enough to notice the wake.
- (void)poll {
  [self.stepTimer invalidate];
  self.stepTimer = nil;
  if (isnan(self.level) || self.display < 0 || !self.dimming) return;
  [self followStep];
  if (self.lastStep == kStepOff) return;
  NSTimeInterval delay = kStepPoll;
  double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
  if (idle < kIdleBeforePolling) delay = kIdleBeforePolling - idle;
  self.stepTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) { [self poll]; }];
  self.stepTimer.tolerance = delay > kStepPoll ? 0.1 : 0.005;
}

- (void)backlightPoweredOn {
  [self poll];
}

@end

static void BacklightMessage(void *keeper, io_service_t service, uint32_t type, void *argument) {
  if (type == kIOMessageDeviceHasPoweredOn) [(__bridge Keeper *)keeper backlightPoweredOn];
}

static BOOL WatchBacklight(Keeper *keeper) {
  io_iterator_t iterator;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"), &iterator)) return NO;
  BOOL watching = NO;
  io_service_t backlight;
  while ((backlight = IOIteratorNext(iterator))) {
    io_registry_entry_t parent;
    io_name_t name = {0};
    if (!IORegistryEntryGetParentEntry(backlight, kIOServicePlane, &parent)) {
      IORegistryEntryGetName(parent, name);
      IOObjectRelease(parent);
    }
    if (!watching && !strcmp(name, "backlight-dfr")) {
      IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
      IONotificationPortSetDispatchQueue(port, dispatch_get_main_queue());
      io_object_t notification;
      watching = IOServiceAddInterestNotification(port, backlight, kIOGeneralInterest, BacklightMessage,
                                                  (__bridge void *)keeper, &notification) == KERN_SUCCESS;
    }
    IOObjectRelease(backlight);
  }
  IOObjectRelease(iterator);
  return watching;
}

static int Run(void) {
  NSString *missing = MissingAPI();
  if (missing) {
    // Exit 0 so launchd does not restart it; the Touch Bar keeps Apple's normal behaviour.
    Log(@"tbkeep %s stopped: %@. The Touch Bar keeps macOS's normal behaviour.", TBKEEP_VERSION, missing);
    return 0;
  }
  Keeper *keeper = [Keeper new];
  keeper.appliedLevel = NAN;
  keeper.minimumNits = NAN;
  keeper.lastNits = NAN;
  [keeper connect];
  [keeper enforce:@"start"];
  Log(@"tbkeep %s running: minimum %@", TBKEEP_VERSION,
      isnan(keeper.level) ? @"none (disabled)" : [NSString stringWithFormat:@"%.0f%%", keeper.level * 100]);

  NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
  for (NSString *name in @[ NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification,
                            NSWorkspaceSessionDidBecomeActiveNotification ]) {
    [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      [keeper enforce:@"wake"];
    }];
  }
  if (!WatchBacklight(keeper)) Log(@"Touch Bar backlight not found; waking from off is caught by the 2 s check only");
  NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
    [keeper enforce:@"check"];
    if (!keeper.stepTimer) [keeper poll];
  }];
  timer.tolerance = 0.2;
  [keeper poll];
  [NSRunLoop.mainRunLoop run];
  return 0;
}

#pragma mark - Commands

static NSString *MacModel(void) {
  char model[64] = {0};
  size_t size = sizeof(model);
  sysctlbyname("hw.model", model, &size, NULL, 0);
  return [NSString stringWithFormat:@"%s, macOS %@", model, NSProcessInfo.processInfo.operatingSystemVersionString];
}

static BOOL AgentRunning(void) {
  NSTask *task = [NSTask new];
  task.launchPath = @"/bin/launchctl";
  task.arguments = @[ @"print", [NSString stringWithFormat:@"gui/%d/%@", getuid(), kAgentLabel] ];
  NSPipe *pipe = [NSPipe pipe];
  task.standardOutput = pipe;
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  [task launch];
  NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
  [task waitUntilExit];
  return [[[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] containsString:@"state = running"];
}

static int Status(BrightnessSystemClient *brightness, long long display) {
  BOOL autoOn = NO;
  double nits = 0, saved = SavedLevel();
  CurrentLevel(brightness, display, &autoOn, &nits);
  printf("tbkeep %s - Touch Bar flicker fix\n", TBKEEP_VERSION);
  printf("Minimum:        %s\n", isnan(saved) ? "none (fix disabled, macOS controls the Touch Bar)"
                                               : [NSString stringWithFormat:@"%.0f%%", saved * 100].UTF8String);
  printf("Touch Bar now:  %s, %.0f nits\n", autoOn ? "auto-brightness" : "held at the minimum", nits);
  printf("Background job: %s\n", AgentRunning() ? "running" : "NOT running (run ./install.sh)");
  return 0;
}

static void ApplySaved(BrightnessSystemClient *brightness, long long display) {
  double saved = SavedLevel();
  if (isnan(saved)) ApplyAuto(brightness, display);
  else ApplyLevel(brightness, display, saved);
}

static int Try(BrightnessSystemClient *brightness, long long display) {
  NSString *previous = ReadSetting(@"level");
  printf("Find your level. Do this in the room where the flicker happens (a dark room is best).\n"
         "At each step, watch the Touch Bar for about 10 seconds, then answer.\n");
  for (int percent = 20; percent <= 100; percent += 10) {
    double level = percent / 100.0;
    WriteSetting(@"level", [NSString stringWithFormat:@"%.2f", level]);  // the background job follows this
    ApplyLevel(brightness, display, level);
    [NSThread sleepForTimeInterval:0.4];
    double nits = 0;
    CurrentLevel(brightness, display, NULL, &nits);
    char answer = 0;
    while (answer != 'y' && answer != 'n' && answer != 'q') {
      printf("\n%d%% (about %.0f nits). Does it flicker? [y = yes, n = no, q = quit]: ", percent, nits);
      fflush(stdout);
      char line[64];
      if (!fgets(line, sizeof line, stdin)) { answer = 'q'; break; }
      answer = (char)tolower((unsigned char)line[0]);
    }
    if (answer == 'q') break;
    if (answer == 'n') {
      int keep = MIN(100, percent + 10);  // a little extra for cold days
      WriteSetting(@"level", [NSString stringWithFormat:@"%.2f", keep / 100.0]);
      ApplyLevel(brightness, display, keep / 100.0);
      printf("\nNo flicker at %d%%. Saved %d%% (a little higher, for cold days).\n"
             "Change it any time with: tbkeep <number>, for example tbkeep %d\n", percent, keep, MIN(100, keep + 10));
      return 0;
    }
    if (percent == 100)
      printf("\nIt flickers even at full brightness, so this fix can't hide it on your Mac.\n");
  }
  WriteSetting(@"level", previous.length ? previous : [NSString stringWithFormat:@"%.2f", kDefaultLevel]);
  ApplySaved(brightness, display);
  printf("\nStopped. Your previous setting is back.\n");
  return 0;
}

static void PrintHelp(void) {
  printf("tbkeep %s - MacBook Pro Touch Bar flicker fix\n\n"
         "  tbkeep              show status\n"
         "  tbkeep 70           set the minimum to 70%% (5-100); use a higher number if it flickers\n"
         "  tbkeep try          find the lowest level with no flicker\n"
         "  tbkeep disable      turn the fix off (macOS controls the Touch Bar alone); tbkeep <number> turns it on\n"
         "  tbkeep uninstall    remove tbkeep completely\n"
         "  tbkeep version      version and Mac model (useful for bug reports)\n",
         TBKEEP_VERSION);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *command = argc > 1 ? [@(argv[1]) lowercaseString] : @"status";

    if ([command isEqualToString:@"help"] || [command hasPrefix:@"-"]) {
      PrintHelp();
      return 0;
    }
    if ([command isEqualToString:@"version"]) {
      printf("tbkeep %s on %s\n", TBKEEP_VERSION, MacModel().UTF8String);
      return 0;
    }
    if ([command isEqualToString:@"uninstall"]) {
      NSString *script = [SupportDir() stringByAppendingPathComponent:@"uninstall.sh"];
      if (![NSFileManager.defaultManager isExecutableFileAtPath:script]) {
        fprintf(stderr, "Uninstaller not found at %s\n", script.UTF8String);
        return 1;
      }
      execl("/bin/bash", "bash", script.UTF8String, (char *)NULL);
      return 1;
    }
    if ([command isEqualToString:@"run"]) return Run();

    NSString *missing = MissingAPI();
    if (missing) {
      fprintf(stderr, "tbkeep can't work on this Mac: %s.\n", missing.UTF8String);
      return 1;
    }
    BrightnessSystemClient *brightness = [[NSClassFromString(@"BrightnessSystemClient") alloc] init];
    DFRBrightnessClient *dimming = [[NSClassFromString(@"DFRBrightnessClient") alloc] init];
    long long display = TouchBarDisplay(brightness, dimming);
    if (display < 0) {
      fprintf(stderr, "No Touch Bar found on this Mac.\n");
      return 1;
    }

    if ([command isEqualToString:@"check"]) {
      printf("OK: Touch Bar found and Apple's brightness services are available.\n");
      return 0;
    }
    if ([command isEqualToString:@"status"]) return Status(brightness, display);
    if ([command isEqualToString:@"try"]) return Try(brightness, display);
    if ([command isEqualToString:@"disable"]) {
      WriteSetting(@"level", @"auto");
      ApplyAuto(brightness, display);
      printf("Disabled: macOS controls the Touch Bar alone again. Turn the fix back on with: tbkeep 40\n");
      return 0;
    }
    NSString *number = [command stringByReplacingOccurrencesOfString:@"%" withString:@""];
    BOOL digitsOnly = number.length > 0 &&
                      [number rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
    int percent = number.intValue;
    if (!digitsOnly || percent < 5 || percent > 100) {
      PrintHelp();
      return 1;
    }
    WriteSetting(@"level", [NSString stringWithFormat:@"%.2f", percent / 100.0]);
    ApplyLevel(brightness, display, percent / 100.0);
    [NSThread sleepForTimeInterval:0.5];
    return Status(brightness, display);
  }
}
