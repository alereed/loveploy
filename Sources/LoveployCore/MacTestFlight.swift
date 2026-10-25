import Foundation

/// Builds for TestFlight on the user's own Macs (GitHub Actions self-hosted runners)
/// instead of on Lovable: Loveploy installs a workflow in the project's repo and
/// dispatches it.
public enum MacTestFlight {
    public static let workflowFile = "loveploy-testflight.yml"
    public static let workflowPath = ".github/workflows/\(workflowFile)"

    /// The next build number after every one Loveploy knows about, when they're plain numbers.
    public static func nextBuildNumber(known: [String?]) -> String? {
        let numbers = known.compactMap { $0.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        return numbers.max().map { String($0 + 1) }
    }

    /// Parses the run title the workflow sets: "TestFlight <build> · <commit> · <loveploy id>".
    static func titleParts(_ run: WorkflowRun) -> [String] {
        (run.displayTitle ?? "").components(separatedBy: " · ")
    }

    /// The workflow file (same as templates/loveploy-testflight.yml).
    public static let workflowYAML = #"""
# Instalado por Loveploy. Compila la app de iOS (Expo) de este proyecto de Lovable
# en un Mac propio (runner self-hosted de GitHub Actions) y la sube a TestFlight.
#
# El Mac necesita Xcode, Node y CocoaPods, y el runner las etiquetas "self-hosted" y "macOS".
# Credenciales de App Store Connect, como secretos (del repo o de la organización)
# o como variables de entorno del runner (archivo .env del runner):
#   ASC_KEY_ID, ASC_ISSUER_ID, APPLE_TEAM_ID y la clave .p8 en ASC_KEY_P8 (secreto) o
#   ASC_KEY_PATH (ruta en el Mac). También sirve ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
name: Loveploy TestFlight
run-name: "TestFlight ${{ inputs.build_number || github.run_number }} · ${{ inputs.commit_sha || github.sha }} · ${{ inputs.loveploy_id || 'manual' }}"

on:
  workflow_dispatch:
    inputs:
      commit_sha:
        description: Commit a compilar (vacío = la rama elegida)
        required: false
      build_number:
        description: Número de build (vacío = número de ejecución)
        required: false
      app_dir:
        description: Carpeta de la app Expo (vacío = detectarla)
        required: false
      loveploy_id:
        description: Identificador para que Loveploy siga esta ejecución
        required: false

concurrency:
  group: loveploy-testflight-${{ github.repository }}
  cancel-in-progress: false

jobs:
  testflight:
    runs-on: [self-hosted, macOS]
    timeout-minutes: 120
    env:
      BUILD_NUMBER: ${{ inputs.build_number || github.run_number }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ inputs.commit_sha || github.ref }}

      - name: Ubicar la app
        id: app
        env:
          APP_DIR: ${{ inputs.app_dir }}
        run: |
          dir="$APP_DIR"
          if [ -z "$dir" ]; then
            config=$(find . -maxdepth 3 \( -name app.json -o -name 'app.config.js' -o -name 'app.config.ts' \) -not -path '*/node_modules/*' | head -1)
            if [ -z "$config" ]; then
              echo "::error::No encontré app.json ni app.config de Expo en el repo."
              exit 1
            fi
            dir=$(dirname "$config")
          fi
          echo "dir=$dir" >> "$GITHUB_OUTPUT"
          echo "App en $dir, build $BUILD_NUMBER"

      - name: Credenciales de App Store Connect
        env:
          SECRET_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          SECRET_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          SECRET_KEY_P8: ${{ secrets.ASC_KEY_P8 }}
          SECRET_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          # Los secretos tienen prioridad; si no hay, se usan las variables del runner.
          key_id="${SECRET_KEY_ID:-${ASC_KEY_ID:-}}"
          issuer_id="${SECRET_ISSUER_ID:-${ASC_ISSUER_ID:-}}"
          team_id="${SECRET_TEAM_ID:-${APPLE_TEAM_ID:-}}"
          key_path="${ASC_KEY_PATH:-}"
          if [ -n "${SECRET_KEY_P8:-}" ]; then
            key_path="$RUNNER_TEMP/AuthKey_$key_id.p8"
            printf '%s\n' "$SECRET_KEY_P8" > "$key_path"
          elif [ -z "$key_path" ] && [ -f "$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8" ]; then
            key_path="$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8"
          fi
          missing=""
          [ -n "$key_id" ] || missing="$missing ASC_KEY_ID"
          [ -n "$issuer_id" ] || missing="$missing ASC_ISSUER_ID"
          [ -n "$team_id" ] || missing="$missing APPLE_TEAM_ID"
          [ -n "$key_path" ] && [ -f "$key_path" ] || missing="$missing ASC_KEY_P8/ASC_KEY_PATH"
          if [ -n "$missing" ]; then
            echo "::error::Faltan credenciales de App Store Connect:$missing"
            exit 1
          fi
          {
            echo "ASC_KEY_ID=$key_id"
            echo "ASC_ISSUER_ID=$issuer_id"
            echo "APPLE_TEAM_ID=$team_id"
            echo "ASC_KEY_PATH=$key_path"
          } >> "$GITHUB_ENV"

      - name: Instalar dependencias
        working-directory: ${{ steps.app.outputs.dir }}
        run: |
          if [ -f bun.lockb ] || [ -f bun.lock ]; then bun install
          elif [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
          elif [ -f yarn.lock ]; then yarn install --frozen-lockfile
          else npm ci || npm install
          fi

      - name: Generar el proyecto de iOS
        working-directory: ${{ steps.app.outputs.dir }}
        run: |
          if [ ! -d ios ]; then
            npx expo prebuild --platform ios --no-install
          fi
          cd ios && pod install

      - name: Compilar y subir a TestFlight
        working-directory: ${{ steps.app.outputs.dir }}/ios
        run: |
          set -o pipefail
          workspace=$(ls -d *.xcworkspace | head -1)
          scheme="${workspace%.xcworkspace}"
          if [ -f "$scheme/Info.plist" ]; then
            /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$scheme/Info.plist"
          fi
          auth=(-allowProvisioningUpdates
                -authenticationKeyPath "$ASC_KEY_PATH"
                -authenticationKeyID "$ASC_KEY_ID"
                -authenticationKeyIssuerID "$ASC_ISSUER_ID")
          archive="$RUNNER_TEMP/$scheme.xcarchive"

          xcodebuild -quiet -workspace "$workspace" -scheme "$scheme" -configuration Release \
            -destination 'generic/platform=iOS' -archivePath "$archive" "${auth[@]}" \
            DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
            archive

          cat > "$RUNNER_TEMP/ExportOptions.plist" <<PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>teamID</key><string>$APPLE_TEAM_ID</string>
            <key>signingStyle</key><string>automatic</string>
            <key>manageAppVersionAndBuildNumber</key><false/>
          </dict>
          </plist>
          PLIST

          xcodebuild -exportArchive -archivePath "$archive" \
            -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist" -exportPath "$RUNNER_TEMP/export" "${auth[@]}"
          echo "### Build $BUILD_NUMBER subido a TestFlight" >> "$GITHUB_STEP_SUMMARY"

      - name: Limpiar
        if: always()
        run: rm -rf "$RUNNER_TEMP"/AuthKey_*.p8 "$RUNNER_TEMP"/*.xcarchive "$RUNNER_TEMP/export" "$RUNNER_TEMP/ExportOptions.plist"

"""#
}

extension WorkflowRun {
    /// The build number this run uploads, from its title.
    public var buildNumber: String? {
        let first = MacTestFlight.titleParts(self).first ?? ""
        guard first.hasPrefix("TestFlight ") else { return nil }
        let number = String(first.dropFirst("TestFlight ".count))
        return number.isEmpty ? nil : number
    }

    /// The commit it builds (the input Loveploy sent, or the branch head).
    public var builtCommit: String? {
        let parts = MacTestFlight.titleParts(self)
        if parts.count >= 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty { return parts[1] }
        return headSha
    }

    /// The ID Loveploy put in the title when it dispatched this run.
    public var loveployID: String? {
        let parts = MacTestFlight.titleParts(self)
        return parts.count >= 3 ? parts[2] : nil
    }

    /// The same run in Lovable's build-run terms, so both count toward "TestFlight is up to date".
    public var asBuildRun: BuildRun {
        let status: String
        if !isFinished {
            status = "running"
        } else {
            switch conclusion {
            case "success": status = "succeeded"
            case "cancelled", "skipped": status = "cancelled"
            case "timed_out": status = "timed_out"
            default: status = "failed"
            }
        }
        return BuildRun(id: "github-\(id)", status: status, commitSha: builtCommit, createdAt: createdAt, requestedTargets: ["ios"])
    }
}
