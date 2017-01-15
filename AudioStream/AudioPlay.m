//
//  AudioPlay.m
//  AudioStreamingOpus
//
//  Created by Roman on 11/5/16.
//  Copyright © 2016 Crane. All rights reserved.
//

#import "AudioPlay.h"
#import "CSIOpusEncoder.h"
#import "CSIOpusDecoder.h"
#include "CSIDataQueue.h"


#define RECV_BUFFER_SIZE 1024

#pragma mark Recording callback

static OSStatus initCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    
    // the data gets rendered here
    AudioBuffer buffer;
    
    // a variable where we check the status
    OSStatus status;
    
    /**
     This is the reference to the object who owns the callback.
     */
    AudioPlay *audioProcessor = (__bridge AudioPlay*) inRefCon;
    
    /**
     on this point we define the number of channels, which is mono
     for the iphone. the number of frames is usally 512 or 1024.
     */
    buffer.mDataByteSize = inNumberFrames * 2; // sample size
    buffer.mNumberChannels = 1; // one channel
    buffer.mData = malloc( inNumberFrames * 2 ); // buffer size
    
    // we put our buffer into a bufferlist array for rendering
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0] = buffer;
    
    // render input and check for error
    status = AudioUnitRender([audioProcessor audioUnit], ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList);
    [audioProcessor hasError:status:__FILE__:__LINE__];
    
    // clean up the buffer
    free(bufferList.mBuffers[0].mData);
    
    return noErr;
}

OSStatus playCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    AudioPlay *audioProcessor = (__bridge AudioPlay*) inRefCon;

    int bytesFilled = [audioProcessor.decoder tryFillBuffer:ioData];
    if(bytesFilled <= 0)
    {
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
    }
    
    return noErr;
}

#pragma mark objective-c class

@implementation AudioPlay
@synthesize audioUnit, audioBuffer, gain;
const AudioUnitElement pInputBusNumber = 1;
const AudioUnitElement pOutputBusNumber = 0;
-(AudioPlay*)init
{
    self = [super init];
    if (self) {
        gain = 5;
        self.sampleRate = 48000;
        
//        [self setupAudioSession];
        [self initializeAudio];
        [self setupEncoder];
        [self setupDecoder];
        [self retriveData];
    }
    return self;
}

-(void)retriveData
{
    [[[_rootRef child:@"StreamChanels"] child:@"audioChanel"] observeEventType:FIRDataEventTypeValue withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
             
        NSString *bufferStr = snapshot.value;
        
        NSData *bufferData = [[NSData alloc] initWithBase64EncodedString:bufferStr options:0];
        
        dispatch_async(self.decodeQueue, ^{[self.decoder decode:bufferData];});
    }];
}
- (void)setupAudioSession
{
    NSError *error;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [audioSession setPreferredSampleRate:48000 error:&error];
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    [audioSession setPreferredIOBufferDuration:0.02 error:&error];
    [audioSession setActive:YES error:&error];
    
    double sampleRate = audioSession.sampleRate;
    double ioBufferDuration = audioSession.IOBufferDuration;
    int samplesPerFrame = (int)(ioBufferDuration * sampleRate) + 1;
    int bytesPerSample = sizeof(AudioSampleType);
    int bytesPerFrame = samplesPerFrame * bytesPerSample;
    
    self.sampleRate = sampleRate;
    self.frameDuration = ioBufferDuration;
    self.samplesPerFrame = samplesPerFrame;
    self.bytesPerSample = bytesPerSample;
    self.bytesPerFrame = bytesPerFrame;
}

-(void)initializeAudio
{
    OSStatus status;
    
    //Force current audio out through speaker
    UInt32 audioRouteOverride = kAudioSessionOverrideAudioRoute_Speaker;
    
    AudioSessionSetProperty (
                             kAudioSessionProperty_OverrideAudioRoute,
                             sizeof (audioRouteOverride),
                             &audioRouteOverride
                             );
    
    // We define the audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output; // we want to ouput
    desc.componentSubType = kAudioUnitSubType_RemoteIO; // we want in and ouput
    desc.componentFlags = 0; // must be zero
    desc.componentFlagsMask = 0; // must be zero
    desc.componentManufacturer = kAudioUnitManufacturer_Apple; // select provider
    
    // find the AU component by description
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    
    // create audio unit by component
    status = AudioComponentInstanceNew(inputComponent, &audioUnit);
    
    
    [self hasError:status:__FILE__:__LINE__];
    
    // define that we want record io on the input bus
    UInt32 flag = 1;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO, // use io
                                  kAudioUnitScope_Input, // scope to input
                                  kInputBus, // select input bus (1)
                                  &flag, // set flag
                                  sizeof(flag));
    [self hasError:status:__FILE__:__LINE__];
    
    // define that we want play on io on the output bus
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO, // use io
                                  kAudioUnitScope_Output, // scope to output
                                  kOutputBus, // select output bus (0)
                                  &flag, // set flag
                                  sizeof(flag));
    [self hasError:status:__FILE__:__LINE__];
    
    /*
     We need to specifie our format on which we want to work.
     We use Linear PCM cause its uncompressed and we work on raw data.
     for more informations check.
     
     We want 16 bits, 2 bytes per packet/frames at 44khz
     */
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate			= SAMPLE_RATE;
    audioFormat.mFormatID			= kAudioFormatLinearPCM;
    audioFormat.mFormatFlags		= kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger;
    audioFormat.mFramesPerPacket	= 1;
    audioFormat.mChannelsPerFrame	= 1;
    audioFormat.mBitsPerChannel		= 16;
    audioFormat.mBytesPerPacket		= 2;
    audioFormat.mBytesPerFrame		= 2;
    
    
    
    // set the format on the output stream
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  kInputBus,
                                  &audioFormat,
                                  sizeof(audioFormat));
    
    [self hasError:status:__FILE__:__LINE__];
    
    // set the format on the input stream
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  kOutputBus,
                                  &audioFormat,
                                  sizeof(audioFormat));
    [self hasError:status:__FILE__:__LINE__];
    
    
    
    /**
     We need to define a callback structure which holds
     a pointer to the recordingCallback and a reference to
     the audio processor object
     */
    AURenderCallbackStruct callbackStruct;
    
    // set recording callback
    callbackStruct.inputProc = initCallback; // recordingCallback pointer
    callbackStruct.inputProcRefCon = (__bridge void * _Nullable)(self);
    
    // set input callback to recording callback on the input bus
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Global,
                                  kInputBus,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    
    [self hasError:status:__FILE__:__LINE__];
    
    /*
     We do the same on the output stream to hear what is coming
     from the input stream
     */
    callbackStruct.inputProc = playCallback;
    callbackStruct.inputProcRefCon = (__bridge void * _Nullable)(self);
    
    // set playbackCallback as callback on our renderer for the output bus
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Global,
                                  kOutputBus,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    [self hasError:status:__FILE__:__LINE__];
    
    // reset flag to 0
    flag = 0;
    
    /*
     we need to tell the audio unit to allocate the render buffer,
     that we can directly write into it.
     */
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_ShouldAllocateBuffer,
                                  kAudioUnitScope_Output,
                                  kInputBus,
                                  &flag,
                                  sizeof(flag));
    
    
    /*
     we set the number of channels to mono and allocate our block size to
     1024 bytes.
     */
    audioBuffer.mNumberChannels = 1;
    audioBuffer.mDataByteSize = 512 * 2;
    audioBuffer.mData = malloc( 512 * 2 );
    
    // Initialize the Audio Unit and cross fingers =)
    status = AudioUnitInitialize(audioUnit);
    [self hasError:status:__FILE__:__LINE__];
    
    NSLog(@"Started");
    
    _rootRef = [[FIRDatabase database] reference];}

#pragma mark controll stream

-(void)start;
{
    // start the audio unit. You should hear something, hopefully :)
    OSStatus status = AudioOutputUnitStart(audioUnit);
    [self hasError:status:__FILE__:__LINE__];
}
-(void)stop;
{
    // stop the audio unit
    OSStatus status = AudioOutputUnitStop(audioUnit);
    [self hasError:status:__FILE__:__LINE__];
}


-(void)setGain:(float)gainValue 
{
    gain = gainValue;
}

-(float)getGain
{
    return gain;
}
- (void)setupEncoder
{
    
    self.encoder = [CSIOpusEncoder encoderWithSampleRate:self.sampleRate channels:1 frameDuration:0.01];
}

- (void)setupDecoder
{
    self.decoder = [CSIOpusDecoder decoderWithSampleRate:self.sampleRate channels:1 frameDuration:0.01];
    self.decodeQueue = dispatch_queue_create("Decode Queue", nil);
}
#pragma mark Error handling

-(void)hasError:(int)statusCode:(char*)file:(int)line 
{
	if (statusCode) {
		printf("Error Code responded %d in file %s on line %d\n", statusCode, file, line);
        exit(-1);
	}
}


@end
