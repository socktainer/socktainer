import Vapor

struct RESTVolumeCreate: Content {
    init(Name: String, Driver: String, Options: [String: String], Labels: [String: String]?) {
        self.Name = Name
        self.Driver = Driver
        self.Options = Options
        self.Labels = Labels
        self.Mountpoint = ""
        self.CreatedAt = nil
        self.Status = nil
        self.Scope = "local"
        self.ClusterVolume = nil
        self.UsageData = VolumeUsageData()
    }
    let Name: String
    let Driver: String
    let Mountpoint: String
    let CreatedAt: String?
    let Status: [String: String]?
    let Labels: [String: String]?
    let Scope: String
    let ClusterVolume: EmptyObject?
    let Options: [String: String]
    let UsageData: VolumeUsageData?
}
