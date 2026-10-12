import Foundation

extension S3Client {
    @MainActor
    init?(_ s: StorageStore) {
        guard s.s3Configured else { return nil }
        self.init(config: S3Config(endpoint: s.s3Endpoint, region: s.s3Region, bucket: s.s3Bucket,
                                   accessKey: s.s3AccessKey, secret: s.s3Secret))
    }
}
