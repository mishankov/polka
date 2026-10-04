import Foundation
import CoreAudio
import CoreMediaIO
import AVFoundation
// Query documented activity only; never open a stream or request microphone access.
func audioObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
 var address = AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
 var size: UInt32 = 0
 guard AudioObjectGetPropertyDataSize(object,&address,0,nil,&size) == noErr else { return nil }
 if size == 0 { return [] }
 var objects = [AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
 let result = objects.withUnsafeMutableBytes { AudioObjectGetPropertyData(object,&address,0,nil,&size,$0.baseAddress!) }
 guard result == noErr else { return nil }
 return Array(objects.prefix(Int(size)/MemoryLayout<AudioObjectID>.size))
}
func audioInputRunning(_ process: AudioObjectID) -> UInt32? {
 var address = AudioObjectPropertyAddress(mSelector:kAudioProcessPropertyIsRunningInput,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var running: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
 return AudioObjectGetPropertyData(process,&address,0,nil,&size,&running) == noErr ? running : nil
}

// A process can report input IO without any device (e.g. CoreSpeech during the
// screenshot shutter sound). Require an associated input device with input streams.
// Do not blacklist Screenshot/CoreSpeech: either can also legitimately use a mic.
func microphoneState(processes: [AudioObjectID]?,
                     runningInput: (AudioObjectID) -> UInt32?,
                     inputDevices: (AudioObjectID) -> [AudioObjectID]?,
                     inputStreams: (AudioObjectID) -> [AudioObjectID]?) -> String {
 guard let processes = processes else { return "unknown" }
 var failures = false
 for process in processes {
  guard let running = runningInput(process) else { failures = true; continue }
  if running == 0 { continue }
  guard let devices = inputDevices(process) else { failures = true; continue }
  for device in devices {
   guard let streams = inputStreams(device) else { failures = true; continue }
   if !streams.isEmpty { return "active" }
  }
 }
 return failures ? "unknown" : "inactive"
}
func microphone() -> [String:Any] {
 guard #available(macOS 14.2, *) else { return ["state":"unknown","detail":"Наблюдение за аудиовходом требует macOS 14.2"] }
 let state = microphoneState(
  processes: audioObjectList(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyProcessObjectList),
  runningInput: audioInputRunning,
  inputDevices: { audioObjectList($0,kAudioProcessPropertyDevices,scope:kAudioObjectPropertyScopeInput) },
  inputStreams: { audioObjectList($0,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeInput) }
 )
 return ["state":state,"detail": state == "unknown"
  ? "Не удалось проверить входные устройства аудиопроцессов"
  : "Активные входные потоки процесса с подключённым аудиовходом; воспроизведение и IO без устройства не считаются использованием микрофона. Mute и передача звука не определяются."]
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
// CLI entry point.
let payload:[String:Any] = ["microphone":microphone(),"camera":camera(),"screen":["state":"unsupported","detail":"Публичный API глобального наблюдения за чужим захватом экрана отсутствует"],"mute":["state":"unsupported","detail":"Mute зависит от приложения"],"timestamp":ISO8601DateFormatter().string(from:Date())]
let data = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]);print(String(data:data,encoding:.utf8)!)
