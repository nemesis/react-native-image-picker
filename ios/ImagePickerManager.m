#import "ImagePickerManager.h"
#import "ImagePickerUtils.h"
#import <React/RCTConvert.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreLocation/CoreLocation.h>

@import MobileCoreServices;

@interface ImagePickerManager ()

@property (nonatomic, strong) RCTResponseSenderBlock callback;
@property (nonatomic, copy) NSDictionary *options;

@end

@implementation ImagePickerManager

NSString *errCameraUnavailable = @"camera_unavailable";
NSString *errPermission = @"permission";
NSString *errOthers = @"others";
RNImagePickerTarget target;

NSDateFormatter* exifCreationTimeFormatter;

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(launchCamera:(NSDictionary *)options callback:(RCTResponseSenderBlock)callback)
{
    target = camera;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self launchImagePicker:options callback:callback];
    });
}

RCT_EXPORT_METHOD(launchImageLibrary:(NSDictionary *)options callback:(RCTResponseSenderBlock)callback)
{
    target = library;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self launchImagePicker:options callback:callback];
    });
}

+ (void)initialize
{
    [super initialize];
    exifCreationTimeFormatter = [[NSDateFormatter alloc] init];
    exifCreationTimeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    [exifCreationTimeFormatter setDateFormat:@"yyyy:MM:dd HH:mm:ss"];
}

- (void)launchImagePicker:(NSDictionary *)options callback:(RCTResponseSenderBlock)callback
{
    self.callback = callback;

    if (target == camera && [ImagePickerUtils isSimulator]) {
        self.callback(@[@{@"errorCode": errCameraUnavailable}]);
        return;
    }

    self.options = options;

    if (@available(iOS 14, *)) {
        if (target == library) {
            PHPickerConfiguration *configuration = [ImagePickerUtils makeConfigurationFromOptions:options target:target];
            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
            picker.delegate = self;
            picker.presentationController.delegate = self;

            [self showPickerViewController:picker];
            return;
        }
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    [ImagePickerUtils setupPickerFromOptions:picker options:self.options target:target];
    picker.delegate = self;

    [self checkPermission:^(BOOL granted) {
        if (!granted) {
            self.callback(@[@{@"errorCode": errPermission}]);
            return;
        }
        [self showPickerViewController:picker];
    }];
}

- (void) showPickerViewController:(UIViewController *)picker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = RCTPresentedViewController();
        [root presentViewController:picker animated:YES completion:nil];
    });
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info
{
    dispatch_block_t dismissCompletionBlock = ^{
        NSMutableArray<NSDictionary *> *assets = [[NSMutableArray alloc] initWithCapacity:1];

        if ([info[UIImagePickerControllerMediaType] isEqualToString:(NSString *) kUTTypeImage]) {
            UIImage *image = [ImagePickerManager getUIImageFromInfo:info];
            [assets addObject:[self mapImageToAsset:image data:[NSData dataWithContentsOfURL:[ImagePickerManager getNSURLFromInfo:info]]]];
        } else {
            NSError *error;
            NSDictionary *asset = [self mapVideoToAsset:info[UIImagePickerControllerMediaURL] error:&error];
            if (asset == nil) {
                self.callback(@[@{@"errorCode": errOthers, @"errorMessage":  error.localizedFailureReason}]);
                return;
            }
            [assets addObject:asset];
        }

        NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
        response[@"assets"] = assets;
        self.callback(@[response]);
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        [picker dismissViewControllerAnimated:YES completion:dismissCompletionBlock];
    });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [picker dismissViewControllerAnimated:YES completion:^{
            self.callback(@[@{@"didCancel": @YES}]);
        }];
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14)){
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.callback(@[@{@"didCancel": @YES}]);
        });
        return;
    }

    NSMutableArray<NSString *> *assetIdentifiers = [[NSMutableArray alloc] initWithCapacity:results.count];
    NSMutableArray<NSDictionary *> *assets = [[NSMutableArray alloc] initWithCapacity:results.count];
    PHImageManager *imageManager = [PHImageManager defaultManager];
    PHImageRequestOptions *requestOptions = [[PHImageRequestOptions alloc] init];

    [requestOptions setNetworkAccessAllowed:YES];
    [requestOptions setSynchronous:YES];

    dispatch_group_t completionGroup = dispatch_group_create();

    for (PHPickerResult *result in results) {
        dispatch_group_enter(completionGroup);

        if (result.assetIdentifier) {
            [assetIdentifiers addObject:result.assetIdentifier];
        }
    }

    PHFetchResult<PHAsset *> *fetchResult = [PHAsset fetchAssetsWithLocalIdentifiers:assetIdentifiers options:nil];
    [fetchResult enumerateObjectsUsingBlock:^(PHAsset* asset, NSUInteger idx, BOOL* stop) {
        NSDate *assetDate = asset.creationDate ? asset.creationDate : asset.modificationDate;

        NSDictionary *locationDictionary;

        if (asset.location) {
            CLLocationCoordinate2D locationCoordinate = asset.location.coordinate;
            locationDictionary = @{ @"latitude": @(locationCoordinate.latitude), @"longitude": @(locationCoordinate.longitude) };
        }

        NSTimeInterval creationTime = [assetDate timeIntervalSince1970];

        NSString *filename = [asset valueForKey:@"filename"];
        NSString *assetExtension = [filename pathExtension];
        NSString *uppercasedExtension = [assetExtension uppercaseString];
        NSString *assetLocalIdentifier = asset.localIdentifier;
        NSString *assetId = [assetLocalIdentifier stringByReplacingOccurrencesOfString:@"/.*" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, assetLocalIdentifier.length)];
        NSString *assetUri = [NSString stringWithFormat:@"assets-library://asset/asset.%@?id=%@&ext=%@", uppercasedExtension, assetId, uppercasedExtension];

        [assets addObject:@{
            @"creationTime": assetDate ? @(creationTime * 1000.0) : [NSNull null],
            @"location": locationDictionary ? locationDictionary : [NSNull null],
            @"localIdentifier": assetLocalIdentifier ? assetLocalIdentifier : [NSNull null],
            @"filename": filename ? filename : [NSNull null],
            @"width": @(asset.pixelWidth),
            @"height": @(asset.pixelHeight),
            @"uri": assetUri,
        }];

        dispatch_group_leave(completionGroup);
    }];

    dispatch_group_notify(completionGroup, dispatch_get_main_queue(), ^{
        NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
        [response setObject:assets forKey:@"assets"];

        self.callback(@[response]);
    });
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    self.callback(@[@{@"didCancel": @YES}]);
}

#pragma mark - Helpers

-(NSMutableDictionary *)mapImageToAsset:(UIImage *)image data:(NSData *)data {
    NSString *fileType = [ImagePickerUtils getFileType:data];

    if ((target == camera) && [self.options[@"saveToPhotos"] boolValue]) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
    }

    if (![fileType isEqualToString:@"gif"]) {
        image = [ImagePickerUtils resizeImage:image
                                     maxWidth:[self.options[@"maxWidth"] floatValue]
                                    maxHeight:[self.options[@"maxHeight"] floatValue]];
    }

    NSMutableDictionary *asset = [[NSMutableDictionary alloc] init];

    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    NSDictionary *metadata = (NSDictionary *) CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSDictionary *exifTiffDictionary = [metadata objectForKey:(NSString *)kCGImagePropertyTIFFDictionary];

    NSString *dateTime = [exifTiffDictionary objectForKey:@"DateTime"];

    if (dateTime) {
        asset[@"creationTime"] = @([exifCreationTimeFormatter dateFromString:@(dateTime.UTF8String)].timeIntervalSince1970 * 1000);
    }

    if ([fileType isEqualToString:@"jpg"]) {
        data = UIImageJPEGRepresentation(image, [self.options[@"quality"] floatValue]);
    } else if ([fileType isEqualToString:@"png"]) {
        data = UIImagePNGRepresentation(image);
    }

    asset[@"type"] = [@"image/" stringByAppendingString:fileType];

    NSString *fileName = [self getImageFileName:fileType];
    NSString *path = [[NSTemporaryDirectory() stringByStandardizingPath] stringByAppendingPathComponent:fileName];
    [data writeToFile:path atomically:YES];

    if ([self.options[@"includeBase64"] boolValue]) {
        asset[@"base64"] = [data base64EncodedStringWithOptions:0];
    }

    NSURL *fileURL = [NSURL fileURLWithPath:path];
    asset[@"uri"] = [fileURL absoluteString];

    NSNumber *fileSizeValue = nil;
    NSError *fileSizeError = nil;
    [fileURL getResourceValue:&fileSizeValue forKey:NSURLFileSizeKey error:&fileSizeError];
    if (fileSizeValue){
        asset[@"fileSize"] = fileSizeValue;
    }

    asset[@"fileName"] = fileName;
    asset[@"width"] = @(image.size.width);
    asset[@"height"] = @(image.size.height);

    return asset;
}

-(NSMutableDictionary *)mapVideoToAsset:(NSURL *)url error:(NSError **)error {
    NSString *fileName = [url lastPathComponent];
    NSString *path = [[NSTemporaryDirectory() stringByStandardizingPath] stringByAppendingPathComponent:fileName];
    NSURL *videoDestinationURL = [NSURL fileURLWithPath:path];

    if ((target == camera) && [self.options[@"saveToPhotos"] boolValue]) {
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil);
    }

    if (![url.URLByResolvingSymlinksInPath.path isEqualToString:videoDestinationURL.URLByResolvingSymlinksInPath.path]) {
        NSFileManager *fileManager = [NSFileManager defaultManager];

        // Delete file if it already exists
        if ([fileManager fileExistsAtPath:videoDestinationURL.path]) {
            [fileManager removeItemAtURL:videoDestinationURL error:nil];
        }

        if (url) { // Protect against reported crash

          // If we have write access to the source file, move it. Otherwise use copy.
          if ([fileManager isWritableFileAtPath:[url path]]) {
            [fileManager moveItemAtURL:url toURL:videoDestinationURL error:error];
          } else {
            [fileManager copyItemAtURL:url toURL:videoDestinationURL error:error];
          }

          if (error) {
              return nil;
          }
        }
    }

    NSMutableDictionary *asset = [[NSMutableDictionary alloc] init];
    asset[@"duration"] = @(roundf(CMTimeGetSeconds([AVAsset assetWithURL:videoDestinationURL].duration)));
    asset[@"uri"] = videoDestinationURL.absoluteString;

    return asset;
}

- (void)checkCameraPermissions:(void(^)(BOOL granted))callback
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        callback(YES);
        return;
    }
    else if (status == AVAuthorizationStatusNotDetermined){
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            callback(granted);
            return;
        }];
    }
    else {
        callback(NO);
    }
}

- (void)checkPhotosPermissions:(void(^)(BOOL granted))callback
{
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized) {
        callback(YES);
        return;
    } else if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                callback(YES);
                return;
            }
            else {
                callback(NO);
                return;
            }
        }];
    }
    else {
        callback(NO);
    }
}

// Both camera and photo write permission is required to take picture/video and store it to public photos
- (void)checkCameraAndPhotoPermission:(void(^)(BOOL granted))callback
{
    [self checkCameraPermissions:^(BOOL cameraGranted) {
        if (!cameraGranted) {
            callback(NO);
            return;
        }

        [self checkPhotosPermissions:^(BOOL photoGranted) {
            if (!photoGranted) {
                callback(NO);
                return;
            }
            callback(YES);
        }];
    }];
}

- (void)checkPermission:(void(^)(BOOL granted)) callback
{
    void (^permissionBlock)(BOOL) = ^(BOOL permissionGranted) {
        if (!permissionGranted) {
            callback(NO);
            return;
        }
        callback(YES);
    };

    if (target == camera && [self.options[@"saveToPhotos"] boolValue]) {
        [self checkCameraAndPhotoPermission:permissionBlock];
    }
    else if (target == camera) {
        [self checkCameraPermissions:permissionBlock];
    }
    else {
        if (@available(iOS 11.0, *)) {
            callback(YES);
        }
        else {
            [self checkPhotosPermissions:permissionBlock];
        }
    }
}

- (NSString *)getImageFileName:(NSString *)fileType
{
    NSString *fileName = [[NSUUID UUID] UUIDString];
    fileName = [fileName stringByAppendingString:@"."];
    return [fileName stringByAppendingString:fileType];
}

+ (UIImage *)getUIImageFromInfo:(NSDictionary *)info
{
    UIImage *image = info[UIImagePickerControllerEditedImage];
    if (!image) {
        image = info[UIImagePickerControllerOriginalImage];
    }
    return image;
}

+ (NSURL *)getNSURLFromInfo:(NSDictionary *)info {
    if (@available(iOS 11.0, *)) {
        return info[UIImagePickerControllerImageURL];
    }
    else {
        return info[UIImagePickerControllerReferenceURL];
    }
}

@end
