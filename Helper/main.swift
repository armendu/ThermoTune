import Foundation

// ThermoTune helper.
//
// The app installs this binary setuid-root in /Library/PrivilegedHelperTools so
// fan speeds can be changed without asking for a password every time. It only
// accepts a few narrowly scoped commands and only ever writes fan keys:
//
//   ThermoTuneHelper status
//   ThermoTuneHelper set <fan> <rpm>     (rpm is clamped to the fan's min/max)
//   ThermoTuneHelper auto <fan>
//   ThermoTuneHelper max-all
//   ThermoTuneHelper auto-all

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "usage: ThermoTuneHelper status | set <fan> <rpm> | max-all | auto <fan> | auto-all"
let args = Array(CommandLine.arguments.dropFirst())

// Promote the real uid as well so the SMC user client sees a root task.
if geteuid() == 0 { _ = setuid(0) }

do {
    let smc = try SMC()
    let fanCount = smc.fanCount()

    func fanIndex(_ string: String) -> Int {
        guard let index = Int(string), (0..<fanCount).contains(index) else {
            fail("invalid fan index '\(string)' (this Mac has \(fanCount) fan(s))", code: 2)
        }
        return index
    }

    if args == ["status"] {
        for fan in smc.fans() {
            print("\(fan.id) actual=\(Int(fan.actual)) target=\(Int(fan.target)) min=\(Int(fan.minimum)) max=\(Int(fan.maximum)) manual=\(fan.isManual) unlocked=\(fan.isControlUnlocked)")
        }
        exit(0)
    }

    guard geteuid() == 0 else { fail("ThermoTuneHelper must run as root to change fan speeds", code: 3) }

    switch args.first {
    case "set" where args.count == 3:
        guard let rpm = Double(args[2]), rpm.isFinite else { fail("invalid rpm '\(args[2])'", code: 2) }
        try smc.setFanManual(fanIndex(args[1]), rpm: rpm)
    case "auto" where args.count == 2:
        try smc.setFanAuto(fanIndex(args[1]))
    case "max-all" where args.count == 1:
        try smc.setAllFansMax()
    case "auto-all" where args.count == 1:
        try smc.setAllFansAuto()
    default:
        fail(usage, code: 2)
    }
} catch {
    fail(error.localizedDescription)
}
