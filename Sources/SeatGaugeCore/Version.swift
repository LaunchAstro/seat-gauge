/// The version this build is. `VERSION` at the root of the checkout says the
/// same, for `build-app.sh` to write into the bundle's Info.plist, and
/// `VersionTests` fails when the two differ, so a bump changes both.
public enum SeatGaugeVersion {
    public static let current = "0.1.0"
}
