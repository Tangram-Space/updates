// SPDX-License-Identifier: GPL-3.0-or-later
// Hosted smoke-test observer only: never launches, signals or force-quits an app.
// B was launched by Sparkle, so waitpid() cannot establish its exit status.
// Register NOTE_EXITSTATUS before requesting normal AppKit termination instead.
#import <Cocoa/Cocoa.h>
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double MonotonicTime(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static BOOL ReadProcess(pid_t pid, NSString *expectedPath, struct proc_bsdinfo *info)
{
    memset(info, 0, sizeof(*info));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, (int)sizeof(*info)) != (int)sizeof(*info) ||
        info->pbi_pid != (uint32_t)pid || info->pbi_uid != getuid()) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    NSString *actualPath = [[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath];
    return [actualPath isEqualToString:expectedPath];
}

static NSString *ProcessBirth(pid_t pid)
{
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"-p", [NSString stringWithFormat:@"%d", pid], @"-o", @"lstart="];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return nil;
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || data.length > 1024) return nil;
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *words = [[value componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"length > 0"]];
    return [words componentsJoinedByString:@" "];
}

static int Finish(NSMutableDictionary *report, NSString *error, double started, int queue)
{
    if (queue >= 0) close(queue);
    report[@"status"] = error ? @"FAIL" : @"PASS";
    if (error) report[@"error"] = error;
    double ended = MonotonicTime();
    if (started >= 0 && ended >= started) report[@"elapsed_seconds"] = @(ended - started);
    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:&serializationError];
    if (!data) {
        fputs("Could not serialize normal-shutdown report.\n", stderr);
        return 1;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    return error ? 1 : 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        double started = MonotonicTime();
        int queue = -1;
        NSMutableDictionary *report = [@{
            @"schema": @1,
            @"method": @"NSRunningApplication.terminate",
            @"exit_observation": @"kqueue NOTE_EXITSTATUS",
            @"normal_termination_requested": @NO,
            @"normal_termination_accepted": @NO,
            @"exit_status_observed": @NO,
            @"signals_sent": @NO
        } mutableCopy];
        @try {
            if (argc != 4 || started < 0 || geteuid() == 0)
                return Finish(report, @"Expected an unprivileged invocation with PID, executable and process birth.", started, queue);
            char *end = NULL;
            errno = 0;
            long rawPid = strtol(argv[1], &end, 10);
            if (errno || !end || *end || rawPid < 2 || rawPid > INT_MAX || rawPid == getpid())
                return Finish(report, @"Invalid target PID.", started, queue);
            pid_t pid = (pid_t)rawPid;
            NSString *expectedPath = [[NSString stringWithUTF8String:argv[2]] stringByResolvingSymlinksInPath];
            NSString *birth = [NSString stringWithUTF8String:argv[3]];
            if (![expectedPath hasPrefix:@"/"] || ![expectedPath hasSuffix:@"/AirPlay.app/Contents/MacOS/uxplay"] || !birth.length)
                return Finish(report, @"Invalid expected AirPlay executable or process birth.", started, queue);
            report[@"pid"] = @(pid);
            report[@"executable"] = expectedPath;
            report[@"birth"] = birth;

            struct proc_bsdinfo before;
            if (!ReadProcess(pid, expectedPath, &before) || ![ProcessBirth(pid) isEqualToString:birth])
                return Finish(report, @"Target PID, owner, executable or birth differs from the observed B.", started, queue);
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            NSString *bundlePath = [[expectedPath stringByDeletingLastPathComponent]
                stringByDeletingLastPathComponent];
            bundlePath = [bundlePath stringByDeletingLastPathComponent];
            if (!app || app.terminated || ![app.bundleIdentifier isEqualToString:@"local.chevy.airplay"] ||
                ![[app.executableURL.path stringByResolvingSymlinksInPath] isEqualToString:expectedPath] ||
                ![[app.bundleURL.path stringByResolvingSymlinksInPath] isEqualToString:bundlePath])
                return Finish(report, @"AppKit identity differs from the observed B.", started, queue);

            queue = kqueue();
            if (queue < 0) return Finish(report, @"Could not create the process-exit observer.", started, queue);
            struct kevent change, receipt;
            EV_SET(&change, pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT | EV_RECEIPT,
                   NOTE_EXIT | NOTE_EXITSTATUS | NOTE_EXEC, 0, NULL);
            if (kevent(queue, &change, 1, &receipt, 1, NULL) != 1 ||
                !(receipt.flags & EV_ERROR) || receipt.data != 0)
                return Finish(report, @"Could not observe the real process exit status; termination was not requested.", started, queue);
            struct proc_bsdinfo after;
            if (!ReadProcess(pid, expectedPath, &after) ||
                before.pbi_start_tvsec != after.pbi_start_tvsec ||
                before.pbi_start_tvusec != after.pbi_start_tvusec)
                return Finish(report, @"B process identity changed before termination.", started, queue);

            report[@"normal_termination_requested"] = @YES;
            BOOL accepted = [app terminate];
            report[@"normal_termination_accepted"] = @(accepted);
            if (!accepted) return Finish(report, @"AppKit declined normal termination.", started, queue);

            double deadline = MonotonicTime() + 30.0;
            for (;;) {
                double remaining = deadline - MonotonicTime();
                if (remaining <= 0)
                    return Finish(report, @"B did not exit within 30 seconds of normal termination.", started, queue);
                struct timespec timeout = {(time_t)remaining,
                    (long)((remaining - (time_t)remaining) * 1000000000.0)};
                struct kevent event;
                int count = kevent(queue, NULL, 0, &event, 1, &timeout);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0 || (event.flags & EV_ERROR) || event.ident != (uintptr_t)pid ||
                    event.filter != EVFILT_PROC || (event.fflags & NOTE_EXEC) ||
                    (event.fflags & (NOTE_EXIT | NOTE_EXITSTATUS)) != (NOTE_EXIT | NOTE_EXITSTATUS))
                    return Finish(report, @"Expected a kernel exit-status event for the unchanged B process.", started, queue);
                int status = (int)event.data;
                report[@"exit_status_observed"] = @YES;
                report[@"raw_wait_status"] = @(status);
                report[@"exited_normally"] = WIFEXITED(status) ? @YES : @NO;
                if (WIFEXITED(status)) report[@"exit_code"] = @(WEXITSTATUS(status));
                if (WIFSIGNALED(status)) report[@"termination_signal"] = @(WTERMSIG(status));
                if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
                    return Finish(report, @"B did not exit normally with status zero.", started, queue);
                return Finish(report, nil, started, queue);
            }
        } @catch (NSException *exception) {
            return Finish(report, [@"Normal-shutdown observer exception: " stringByAppendingString:exception.name], started, queue);
        }
    }
}
