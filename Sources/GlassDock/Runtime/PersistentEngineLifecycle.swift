import Vapor

struct PersistentEngineLifecycle: LifecycleHandler {
    let engine: PersistentEngine

    func shutdownAsync(_ application: Application) async {
        await engine.shutdown()
    }
}
