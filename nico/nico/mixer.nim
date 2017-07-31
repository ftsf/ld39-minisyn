when defined(js):
  import webaudio

import sndfile
import math
import random
import strutils

import sdl2.sdl

export pauseAudio


{.this:self.}

# simple audio mixer for nico

const musicBufferSize = 4096

var tickFunc: proc() = nil

var currentBpm: Natural = 128
var currentTpb: Natural = 4
var sampleRate = 44100.0
var nextTick = 0



type
  SfxBuffer = ref object
    data: seq[float32]
    rate: float
    channels: range[1..2]
    length: int

type
  Node = ref object of RootObj
    sampleId: uint32
    output: float32
  Effect = ref object of Node
  Source = ref object of Node

  Sink = ref object of Node
    inputs: seq[Node]

  GainNode = ref object of Sink
    gain: float

  FilterKind = enum
    Lowpass
    Highpass
    Bandpass
    Notch

  FilterNode = ref object of Sink
    kind: FilterKind
    freq: float
    resonance: float

  SfxSource = ref object of Source
    buffer: SfxBuffer
    position: float
    speed: float
    loop: int
    finished: bool

  MusicSource = ref object of Source
    handle: ptr TSNDFILE
    buffers: array[2,seq[float32]]
    buffer: int
    rate: float
    channels: range[1..2]
    length: int
    position: float
    bufferPosition: float
    speed: float
    canFill: bool
    loop: int
    finished: bool

  AudioOutputNode = ref object of Sink
    sampleBuffer: seq[float32]

  ChannelKind = enum
    channelNone
    channelSynth
    channelWave
    channelMusic

  FXKind* = enum
    fxDelay
    fxReverb
    fxLP
    fxHP
    fxBP
    fxClip
    fxWrap

  SynthShape* = enum
    synSame = "-"
    synSin = "sin"
    synSqr = "sqr"
    synSaw = "saw"
    synTri = "tri"
    synNoise = "rnd"

  Channel = object
    kind: ChannelKind
    phase: float
    freq: float
    width: float
    shape: SynthShape
    gain: float
    init: float
    change: float
    trigger: bool
    lfsr: int
    nextClick: int
    outvalue: float32
    fxKind: FXKind
    fxData1: float
    fxData2: float
    fxData3: float

var audioSampleId: uint32
var audioOutputNode: AudioOutputNode
var audioChannels: seq[Channel]

var invSampleRate: float

proc setTickFunc*(f: proc()) =
  tickFunc = f

proc newSfxBuffer(filename: string): SfxBuffer =
  echo "loading sfx: ", filename
  result = new(SfxBuffer)
  var info: Tinfo
  zeroMem(info.addr, sizeof(Tinfo))
  var fp = sndfile.open(filename.cstring, READ, info.addr)
  echo "file opened"
  if fp == nil:
    raise newException(IOError, "unable to open file for reading: " & filename)

  result.data = newSeq[float32](info.frames * info.channels)
  result.rate = info.samplerate.float
  result.channels = info.channels
  result.length = info.frames.int * info.channels.int

  var loaded = 0
  while loaded < result.length:
    let count = fp.read_float(result.data[loaded].addr, min(result.length - loaded,1024))
    loaded += count.int

  discard fp.close()

  echo "loaded sfx: " & filename & " frames: " & $result.length
  echo result.channels
  echo result.rate

proc cleanupMusicSource(self: MusicSource) =
  if self.handle != nil:
    discard self.handle.close()

proc fill*(self: MusicSource) =
  let otherbuffer = (buffer + 1) mod 2
  discard handle.read_float(buffers[otherbuffer][0].addr, musicBufferSize)
  canFill = false

proc newMusicSource(filename: string, loop: int = 0): MusicSource =
  new(result, cleanupMusicSource)
  var info: Tinfo
  var snd = sndfile.open(filename.cstring, READ, info.addr)
  if snd == nil:
    raise newException(IOError, "unable to open file for reading: " & filename)

  result.handle = snd
  result.buffers[0] = newSeq[float32](musicBufferSize)
  result.buffers[1] = newSeq[float32](musicBufferSize)
  result.buffer = 1
  result.rate = info.samplerate.float
  result.channels = info.channels
  result.length = info.frames.int * info.channels.int
  result.canFill = true
  result.fill()
  result.loop = loop

proc shutdownMixer() =
  echo "closing mixer"
  discard

proc connect*(a: Node, b: Sink) =
  assert(b != nil)
  assert(a != nil)
  b.inputs.safeAdd(a)

proc lerp[T](a,b: T, t: float): T =
  return a + (b - a) * t

proc interpolatedLookup[T](a: seq[T], s: float): T =
  let alpha = s mod 1.0
  if s.int < a.len - 1:
    result = lerp(a[s.int],a[s.int+1],alpha)

method process(self: Node) {.base.} =
  output = 0.0

method process(self: SfxSource) =
  if buffer != nil:
    let s = position.int
    if s >= 0 and s < buffer.data.len:
      output = buffer.data.interpolatedLookup(position)
    if buffer.channels == 2 or sampleId mod 2 == 1:
      position += speed

method process(self: MusicSource) =
  if finished:
    output = 0.0
    return
  let s = bufferPosition.int
  if s >= 0 and s < buffers[buffer].len:
    output = buffers[buffer].interpolatedLookup(bufferPosition)
  if channels == 2 or sampleId mod 2 == 1:
    position += speed
    bufferPosition += speed
    if position.int >= length:
      # reached end of file
      if loop > 0 or loop == -1:
        if loop > 0:
          loop -= 1
          if loop == -1:
            finished = true
            output = 0.0
            return
        discard handle.seek(0, SEEK_SET)
        position = 0
        canFill = true
      else:
        finished = true
        output = 0.0
        return
    if bufferPosition.int >= buffers[buffer].len:
      buffer = (buffer + 1) mod 2
      canFill = true
      bufferPosition = 0

method process(self: Sink) =
  if self.sampleId != audioSampleId:
    output = 0.0
    for input in inputs:
      input.process()
      output += input.output
    self.sampleId = audioSampleId

proc getAudioOutput*(): AudioOutputNode =
  return audioOutputNode

proc getAudioBuffer*(): seq[float32] =
  return audioOutputNode.sampleBuffer

proc noteStrToNote(s: string): int =
  let noteChar = s[0]
  let note = case noteChar
    of 'C': 0
    of 'D': 2
    of 'E': 4
    of 'F': 5
    of 'G': 7
    of 'A': 9
    of 'B': 11
    else: 0
  let sharp = s[1] == '#'
  let octave = parseInt($s[2])
  return 12 * octave + note + (if sharp: 1 else: 0)

proc note*(n: int): float =
  # takes a note integer and converts it to a frequency float
  # synth(0, sin, note(48))
  return pow(2.0, ((n.float - 69.0) / 12.0)) * 440.0

proc note*(n: string): float =
  return note(noteStrToNote(n))

proc synth*(channel: int, shape: SynthShape, freq: float, width: float = 0.5, init: float = 1.0, change: float = 0.0) =
  if channel > audioChannels.high:
    raise newException(KeyError, "invalid channel: " & $channel)
  audioChannels[channel].kind = channelSynth
  audioChannels[channel].shape = shape
  audioChannels[channel].freq = freq
  audioChannels[channel].width = width
  audioChannels[channel].trigger = true
  audioChannels[channel].gain = init
  audioChannels[channel].change = change
  if shape == synNoise:
    audioChannels[channel].lfsr = 0xfeed

proc synthUpdate*(channel: int, shape: SynthShape, freq: float, width: float = 0.5) =
  if channel > audioChannels.high:
    raise newException(KeyError, "invalid channel: " & $channel)
  if shape != synSame:
    audioChannels[channel].shape = shape
  audioChannels[channel].freq = freq
  if width != 0.0:
    audioChannels[channel].width = width

proc channelfx*(channel: int, fxKind: FXKind, data1, data2, data3: float = 0.0) =
  if channel > audioChannels.high:
    raise newException(KeyError, "invalid channel: " & $channel)
  # sets the audio FX for the specified channel
  audioChannels[channel].fxKind = fxKind
  audioChannels[channel].fxData1 = data1
  audioChannels[channel].fxData2 = data2
  audioChannels[channel].fxData3 = data3

proc process(self: var Channel): float32 =
  case kind:
  of channelNone:
    return 0.0
  of channelSynth:
    phase += (freq * invSampleRate) * TAU
    phase = phase mod TAU
    var o: float32 = 0.0
    case self.shape:
    of synSin:
      o = sin(phase)
    of synSqr:
      o = ((if phase mod TAU < (TAU * clamp(width, 0.001, 0.999)): 1.0 else: -1.0) * 0.577).float32
    of synTri:
      o = ((abs((phase mod TAU) / TAU * 2.0 - 1.0)*2.0 - 1.0) * 0.7).float32
    of synSaw:
      o = ((((phase mod TAU) - PI) / PI) * 0.5).float32
    of synNoise:
      if nextClick <= 0:
        let lsb: uint = (lfsr and 1)
        lfsr = lfsr shr 1
        if lsb == 1:
          lfsr = lfsr xor 0xb400
        outvalue = if lsb == 1: 1.0 else: -1.0
        nextClick = ((1.0 / freq) * sampleRate).int
      nextClick -= 1
      o = outvalue
    else:
      o = 0.0
    o = o * gain
    if change > 0:
      gain += change * invSampleRate
      if gain >= 1.0:
        gain = 1.0
        change = 0.0
    if change < 0:
      gain += change * invSampleRate
      if gain <= 0.0:
        change = 0.0
        gain = 0.0
    return o
  else:
    return 0.0

proc bpm*(newBpm: Natural) =
  currentBpm = newBpm

proc tpb*(newTpb: Natural) =
  currentTpb = newTpb

proc audioCallback(userdata: pointer, stream: ptr uint8, bytes: cint) {.cdecl.} =
  setupForeignThreadGc()
  var samples = cast[ptr array[int32.high,float32]](stream)
  let nSamples = bytes div sizeof(float32)
  for i in 0..<nSamples:
    nextTick -= 1
    if nextTick <= 0 and tickFunc != nil:
      tickFunc()
      nextTick = (sampleRate / (currentBpm.float / 60.0 * currentTpb.float)).int
    if i mod 2 == 1:
      samples[i] = samples[i-1]
    else:
      samples[i] = 0
      for j in 0..<audioChannels.len:
        samples[i] += audioChannels[j].process()
      audioOutputNode.sampleBuffer[i] = samples[i]
      audioSampleId += 1

var customAudioCallback: proc(samples: pointer, nSamples: int) = nil

proc customAudioCallbackWrapper(userdata: pointer, stream: ptr uint8, bytes: cint) {.cdecl.} =
  setupForeignThreadGc()
  var samples = cast[ptr array[int32.high,float32]](stream)
  let nSamples = bytes div sizeof(float32)
  customAudioCallback(samples, nSamples)

proc setAudioCallback*(cfunc: proc(samples: pointer, nSamples: int)) =
  customAudioCallback = cfunc

  if sdl.init(INIT_AUDIO) != 0:
    raise newException(Exception, "Unable to initialize audio")

  var audioSpec: AudioSpec
  audioSpec.freq = 44100.cint
  audioSpec.format = AUDIO_F32
  audioSpec.channels = 2
  audioSpec.samples = musicBufferSize
  audioSpec.padding = 0
  audioSpec.callback = customAudioCallbackWrapper
  audioSpec.userdata = nil

  var obtained: AudioSpec
  if openAudio(audioSpec.addr, obtained.addr) != 0:
    raise newException(Exception, "Unable to open audio device: " & $getError())

  sampleRate = obtained.freq.float
  invSampleRate = 1.0 / obtained.freq.float

  echo obtained

  # start the audio thread
  pauseAudio(0)

  echo "audio initialised"

proc getMusic*(): int =
  return 0

proc initMixer*(nChannels: Natural = 16) =
  when defined(js):
    # use web audio
    discard
  else:
    echo "initMixer"
    if sdl.init(INIT_AUDIO) != 0:
      raise newException(Exception, "Unable to initialize audio")

    var audioSpec: AudioSpec
    audioSpec.freq = 44100.cint
    audioSpec.format = AUDIO_F32
    audioSpec.channels = 2
    audioSpec.samples = musicBufferSize
    audioSpec.padding = 0
    audioSpec.callback = audioCallback
    audioSpec.userdata = nil

    var obtained: AudioSpec
    if openAudio(audioSpec.addr, obtained.addr) != 0:
      raise newException(Exception, "Unable to open audio device: " & $getError())

    sampleRate = obtained.freq.float
    invSampleRate = 1.0 / obtained.freq.float

    echo obtained

    audioOutputNode = new(AudioOutputNode)
    audioOutputNode.sampleBuffer = newSeq[float32](obtained.samples * obtained.channels)

    audioChannels = newSeq[Channel](nChannels)

    # start the audio thread
    pauseAudio(0)

    echo "audio initialised"

  addQuitProc(proc() {.noconv.} =
    shutdownMixer()
  )

when isMainModule:
  initMixer(16)
  var music = newMusicSource("test.ogg", -1)
  music.speed = 1.0
  music.play()
  var nz = newNoiseSource(440.0)
  nz.play()
  while true:
    if music.canFill:
      music.fill()
    delay(0)
    nz.freq -= 0.01
    if nz.freq < 0.01:
      nz.freq = 4096.0
