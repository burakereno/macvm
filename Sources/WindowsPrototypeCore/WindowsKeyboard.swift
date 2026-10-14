import Foundation
import IOKit.hidsystem

/// Use physical Apple key positions, translated through QEMU's US RFB keymap.
/// Windows' own selected keyboard layout then produces the intended characters.
/// Host Turkish/dead-key Unicode values must not become unmappable RFB keysyms.
public enum WindowsKeyboard {
    private static let letters: [UInt16: Character] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",49:" ",50:"`"]
    private static let special: [UInt16: UInt32] = [36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,117:0xffff,
        123:0xff51,124:0xff53,125:0xff54,126:0xff52,115:0xff50,119:0xff57,116:0xff55,121:0xff56,
        122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,
        101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9,76:0xff8d,65:0xffae,67:0xffaa,69:0xffab,
        75:0xffaf,78:0xffad,81:0xffbd,82:0xffb0,83:0xffb1,84:0xffb2,85:0xffb3,86:0xffb4,
        87:0xffb5,88:0xffb6,89:0xffb7,91:0xffb8,92:0xffb9,71:0xff7f]
    public static func keysym(keyCode: UInt16) -> UInt32? {
        special[keyCode] ?? letters[keyCode]?.unicodeScalars.first?.value
    }
    public static func modifier(keyCode: UInt16) -> UInt32? {
        [56:0xffe1,60:0xffe2,59:0xffe3,62:0xffe4,58:0xffe9,61:0xffea,55:0xffeb,54:0xffec][keyCode]
    }
    public static func modifiers(rawFlags: UInt) -> Set<UInt32> {
        let groups: [(UInt, UInt, UInt, UInt32, UInt32)] = [
            (UInt(NX_SHIFTMASK), UInt(NX_DEVICELSHIFTKEYMASK), UInt(NX_DEVICERSHIFTKEYMASK), 0xffe1, 0xffe2),
            (UInt(NX_CONTROLMASK), UInt(NX_DEVICELCTLKEYMASK), UInt(NX_DEVICERCTLKEYMASK), 0xffe3, 0xffe4),
            (UInt(NX_ALTERNATEMASK), UInt(NX_DEVICELALTKEYMASK), UInt(NX_DEVICERALTKEYMASK), 0xffe9, 0xffea),
            (UInt(NX_COMMANDMASK), UInt(NX_DEVICELCMDKEYMASK), UInt(NX_DEVICERCMDKEYMASK), 0xffeb, 0xffec)
        ]
        var result = Set<UInt32>()
        for (aggregate, leftMask, rightMask, left, right) in groups where rawFlags & aggregate != 0 {
            if rawFlags & leftMask != 0 { result.insert(left) }
            if rawFlags & rightMask != 0 { result.insert(right) }
            // Synthetic events may contain only device-independent flags.
            if rawFlags & (leftMask | rightMask) == 0 { result.insert(left) }
        }
        return result
    }
}
