# EventsPRO Timer Studio

Only Timer Studio is open source here, under MIT. The rest of the EventsPRO TOOLS suite is excluded and its licence is unchanged.

Download and extract **Timer-Studio-source-20261022.tar.gz** for the complete standalone source, third-party notices, editable web resources, build instructions, local-network tests and a Windows CI workflow template. No private suite repository or history is included. Generic project/menu helpers are copies used only by Timer.

The existing Mac application and hosted suite are unchanged.

## Verification and Windows status

The standalone source passed `go test ./...` and cross-compilation to Windows x64 on macOS. Installation, Chrome/Defender acceptance and offline operation on an actual Windows computer are not yet verified. This is a source publication, not a signed Windows release. Signing service approval has not been obtained.

The complete build instructions and privacy details are in the archive README. Dependencies retain their own licences, including Apache-2.0 jsQR, MIT qrcode-generator and the Microsoft WebView2 SDK redistributable licence. Verify the archive against SHA256SUMS.txt.
