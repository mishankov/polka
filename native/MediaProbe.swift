import Foundation
import CoreAudio
import CoreMediaIO
import AVFoundation
// Query documented device activity, never infer call/mute/transmission state.
func microphone() -> [String:Any] {
 var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var size:UInt32 = 0
 guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr else { return ["state":"unknown","detail":"Не удалось получить устройства"] }
 var devices = [AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
 let result = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!) }
 guard result == noErr else {return ["state":"unknown"]}
 var seen = 0; var failures = false
 for device in devices {
  var inputAddress = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
  var inputSize:UInt32 = 0
  guard AudioObjectGetPropertyDataSize(device,&inputAddress,0,nil,&inputSize) == noErr, inputSize > 0 else {continue}
  seen += 1
  var runningAddress = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceIsRunningSomewhere,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
  var running:UInt32 = 0;var runningSize = UInt32(MemoryLayout<UInt32>.size)
  if AudioObjectGetPropertyData(device,&runningAddress,0,nil,&runningSize,&running) != noErr {failures = true;continue}
  if running != 0 {return ["state":"active","detail":"Устройство с аудиовходом используется. Звонок и mute не определяются; у duplex-устройств возможна активность вывода."]}
 }
 return ["state":seen == 0 || failures ? "unknown":"inactive","detail":"Состояние доступных устройств с аудиовходом; источник и передача звука неизвестны"]
}
func camera() -> [String:Any] {
 var address = CMIOObjectPropertyAddress(mSelector:CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),mScope:CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),mElement:CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
 var size:UInt32 = 0
 guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),&address,0,nil,&size) == noErr, size > 0 else {return ["state":"unknown","detail":"Список камер недоступен"]}
 var devices = [CMIODeviceID](repeating:0,count:Int(size)/MemoryLayout<CMIODeviceID>.size);var used:UInt32 = 0
 let result = devices.withUnsafeMutableBytes { CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),&address,0,nil,size,&used,$0.baseAddress!) }
 guard result == noErr else {return ["state":"unknown"]}
 var failures = false
 for device in devices {
  var runAddress = CMIOObjectPropertyAddress(mSelector:CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),mScope:CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),mElement:CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
  var running:UInt32 = 0;var used:UInt32 = 0
  if CMIOObjectGetPropertyData(device,&runAddress,0,nil,UInt32(MemoryLayout<UInt32>.size),&used,&running) != noErr {failures = true;continue}
  if running != 0 {return ["state":"active","detail":"Доступная камера используется; приложение-источник неизвестно"]}
 }
 return ["state":failures ? "unknown":"inactive","detail":"Только устройства, перечисленные CoreMediaIO; полнота списка не гарантируется"]
}
let payload:[String:Any] = ["microphone":microphone(),"camera":camera(),"screen":["state":"unsupported","detail":"Публичный API глобального наблюдения за чужим захватом экрана отсутствует"],"mute":["state":"unsupported","detail":"Mute зависит от приложения"],"timestamp":ISO8601DateFormatter().string(from:Date())]
let data = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!)
