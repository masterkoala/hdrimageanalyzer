// SwiftOFXBridge.h
// Bridge header for OFX SDK integration in HDRImageAnalyzerPro

#ifndef SwiftOFXBridge_h
#define SwiftOFXBridge_h

#import <Foundation/Foundation.h>

// MARK: - OFX Plugin Registry

@interface OFXPluginRegistry : NSObject

/// Singleton instance of the registry
+ (instancetype)shared;

/// Register a new plugin with the system
- (BOOL)registerPlugin:(id<OFXPlugin>)plugin;

/// Unregister a plugin by its identifier
- (BOOL)unregisterPluginWithIdentifier:(NSString *)pluginId;

/// Get all registered plugins
@property (nonatomic, readonly, copy) NSArray *registeredPlugins;

/// Check if a specific plugin is registered
- (BOOL)isPluginRegistered:(NSString *)pluginId;

@end

// MARK: - OFX Plugin Protocol

@protocol OFXPlugin <NSObject>

@required

/// Unique identifier for this plugin
@property (nonatomic, readonly) NSString *pluginId;

/// Display name shown to users
@property (nonatomic, readonly) NSString *name;

/// Plugin version string
@property (nonatomic, readonly) NSString *version;

/// Initialize the plugin
- (BOOL)initialize;

/// Deinitialize and clean up resources
- (void)deinitialize;

/// Get supported capabilities
- (NSArray *)getCapabilities;

/// Process a frame through the plugin
- (NSData *)processFrame:(NSData *)frameData;

/// Start plugin operation
- (BOOL)start;

/// Stop plugin operation
- (void)stop;

@optional

/// Plugin metadata
@property (nonatomic, readonly) NSDictionary *metadata;

/// Get plugin configuration
- (NSDictionary *)getConfig;

/// Set plugin configuration
- (void)setConfig:(NSDictionary *)config;

@end

// MARK: - OFX Input Source

@protocol OFXInputSource <OFXPlugin>

@required

/// Get current frame data from input source
- (NSData *)getCurrentFrame;

/// Check if input signal is present
@property (nonatomic, readonly) BOOL hasSignal;

/// Get signal state
@property (nonatomic, readonly) NSString *signalState;

@end

// MARK: - OFX Video Simulation

@interface OFXVideoSimulation : NSObject <OFXPlugin>

@property (nonatomic, readonly) NSString *simulationId;
@property (nonatomic, readonly) NSString *simulationType;
@property (nonatomic, assign) CGSize resolution;
@property (nonatomic, assign) double frameRate;

/// Create a test pattern simulation
+ (instancetype)testPatternSimulationWithResolution:(CGSize)resolution frameRate:(double)frameRate;

/// Create calibration sequence simulation
+ (instancetype)calibrationSimulationWithResolution:(CGSize)resolution frameRate:(double)frameRate;

/// Create video playback simulation
+ (instancetype)videoPlaybackSimulationWithName:(NSString *)name resolution:(CGSize)resolution frameRate:(double)frameRate;

@end

// MARK: - Frame Data Wrapper

@interface OFXFrameData : NSObject

@property (nonatomic, readonly) NSData *pixels;
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) OSType pixelFormat;
@property (nonatomic, assign) double frameTimestamp;

/// Initialize with raw pixel data and dimensions
- (instancetype)initWithPixels:(NSData *)pixels width:(NSInteger)width height:(NSInteger)height format:(OSType)format;

@end

// MARK: - Resolve Connection Manager

@interface OFXResolveConnection : NSObject

/// Connect to DaVinci Resolve's OFX sharing mechanism
+ (BOOL)connectToResolveWithIdentifier:(NSString *)appId;

/// Disconnect from Resolve
+ (void)disconnectFromResolve;

/// Check if connected to Resolve
+ (BOOL)isConnected;

/// Get connection URL
+ (NSString *)connectionURL;

@end

// MARK: - Plugin Manager Extensions

@interface OFXPluginManager ()

- (NSDictionary *)pluginManifestForPluginId:(NSString *)pluginId;
- (NSURL *)pluginBundlePathForPluginId:(NSString *)pluginId;

@end

#endif /* SwiftOFXBridge_h */
