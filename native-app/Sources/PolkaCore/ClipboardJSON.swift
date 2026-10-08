import Foundation

/// A truncated UTF-16 preview may contain a lone surrogate.
/// JSON permits that escaped representation, but Foundation rejects it. Swift
/// strings render it as a replacement character; keep all other code units intact.
public func decodeClipboardJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
  do { return try JSONDecoder().decode(type, from: data) } catch {
    let originalError = error
    let bytes = Array(data)
    var repaired: [UInt8] = []
    repaired.reserveCapacity(bytes.count)
    var index = 0
    var inString = false
    var changed = false
    func unicode(_ offset: Int) -> UInt16? {
      guard offset + 5 < bytes.count, bytes[offset] == 92, bytes[offset + 1] == 117 else {
        return nil
      }
      var value: UInt16 = 0
      for byte in bytes[(offset + 2)...(offset + 5)] {
        let digit: UInt16
        switch byte {
        case 48...57: digit = UInt16(byte - 48)
        case 65...70: digit = UInt16(byte - 55)
        case 97...102: digit = UInt16(byte - 87)
        default: return nil
        }
        value = (value << 4) | digit
      }
      return value
    }
    while index < bytes.count {
      let byte = bytes[index]
      if inString, byte == 92, index + 1 < bytes.count {
        if let value = unicode(index), (0xD800...0xDFFF).contains(value) {
          if (0xD800...0xDBFF).contains(value), let low = unicode(index + 6),
            (0xDC00...0xDFFF).contains(low)
          {
            repaired.append(contentsOf: bytes[index..<(index + 12)])
            index += 12
          } else {
            repaired.append(contentsOf: [92, 117, 102, 102, 102, 100])  // \ufffd
            index += 6
            changed = true
          }
        } else {
          repaired.append(contentsOf: bytes[index..<(index + 2)])
          index += 2
        }
      } else {
        if byte == 34 { inString.toggle() }
        repaired.append(byte)
        index += 1
      }
    }
    guard changed else { throw originalError }
    return try JSONDecoder().decode(type, from: Data(repaired))
  }
}
