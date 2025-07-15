#
# crate2nix/default.nix (excerpt start)
#{#
{ pkgs
, lib
, stdenv
, buildRustCrate
, buildRustCrateForPkgs ? if buildRustCrate != null then
    lib.warn "`buildRustCrate` is deprecated, use `buildRustCrateForPkgs` instead" (_: buildRustCrate)
  else
    pkgs: pkgs.buildRustCrate
, defaultCrateOverrides
, strictDeprecation ? true
, crates ? { }
, rootFeatures ? [ ]
, targetFeatures ? [ ]
, release ? true
,
}:
rec {
  # #}

  /*
    Target (platform) data for conditional dependencies.
    This corresponds roughly to what buildRustCrate is setting.
  */
  makeDefaultTarget = platform: {
    name = platform.rust.rustcTarget;

    unix = platform.isUnix;
    windows = platform.isWindows;
    fuchsia = true;
    test = false;

    inherit (platform.rust.platform)
      arch
      os
      vendor
      ;
    family = platform.rust.platform.target-family;
    env = platform.parsed.abi.name;
    endian = if platform.parsed.cpu.significantByte.name == "littleEndian" then "little" else "big";
    pointer_width = toString platform.parsed.cpu.bits;
    debug_assertions = false;
    has_atomic =
      let
        maxAtomic =
          hasAtomicData.standardArchs.${platform.rust.platform.arch}
          or hasAtomicData.nonStandardTargets.${platform.rust.rustcTarget}
          or null;
        possibleAtomics = [ 8 16 32 64 128 ];
        atomics = (lib.filter (a: a <= maxAtomic) possibleAtomics);
      in
        if maxAtomic == null then []
        else (lib.map toString atomics) ++ [ "ptr" ];
  };

  registryUrl =
    { registries
    , url
    , crate
    , version
    , sha256
    ,
    }:
    let
      dl = registries.${url}.dl;
      tmpl = [
        "{crate}"
        "{version}"
        "{prefix}"
        "{lowerprefix}"
        "{sha256-checksum}"
      ];
    in
    with lib.strings;
    if lib.lists.any (i: hasInfix "{}" dl) tmpl then
      let
        prefix =
          if builtins.stringLength crate == 1 then
            "1"
          else if builtins.stringLength crate == 2 then
            "2"
          else
            "${builtins.substring 0 2 crate}/${builtins.substring 2 (builtins.stringLength crate - 2) crate}";
      in
      builtins.replaceStrings tmpl [
        crate
        version
        prefix
        (lib.strings.toLower prefix)
        sha256
      ]
    else
      "${dl}/${crate}/${version}/download";

  # Filters common temp files and build files.
  # TODO(pkolloch): Substitute with gitignore filter
  sourceFilter =
    name: type:
    let
      baseName = builtins.baseNameOf (builtins.toString name);
    in
      !(
        # Filter out git
        baseName == ".gitignore"
        || (type == "directory" && baseName == ".git")

        # Filter out build results
        || (
          type == "directory"
          && (
            baseName == "target"
            || baseName == "_site"
            || baseName == ".sass-cache"
            || baseName == ".jekyll-metadata"
            || baseName == "build-artifacts"
          )
        )

        # Filter out nix-build result symlinks
        || (type == "symlink" && lib.hasPrefix "result" baseName)

        # Filter out IDE config
        || (type == "directory" && (baseName == ".idea" || baseName == ".vscode"))
        || lib.hasSuffix ".iml" baseName

        # Filter out nix build files
        || baseName == "Cargo.nix"

        # Filter out editor backup / swap files.
        || lib.hasSuffix "~" baseName
        || builtins.match "^\\.sw[a-z]$$" baseName != null
        || builtins.match "^\\..*\\.sw[a-z]$$" baseName != null
        || lib.hasSuffix ".tmp" baseName
        || lib.hasSuffix ".bak" baseName
        || baseName == "tests.nix"
      );

  /*
    Returns a crate which depends on successful test execution
    of crate given as the second argument.

    testCrateFlags: list of flags to pass to the test exectuable
    testInputs: list of packages that should be available during test execution
  */
  crateWithTest =
    { crate
    , testCrate
    , testCrateFlags
    , testInputs
    , testPreRun
    , testPostRun
    ,
    }:
      assert builtins.typeOf testCrateFlags == "list";
      assert builtins.typeOf testInputs == "list";
      assert builtins.typeOf testPreRun == "string";
      assert builtins.typeOf testPostRun == "string";
      let
        # override the `crate` so that it will build and execute tests instead of
        # building the actual lib and bin targets We just have to pass `--test`
        # to rustc and it will do the right thing.  We execute the tests and copy
        # their log and the test executables to $out for later inspection.
        test =
          let
            drv = testCrate.override (_: {
              buildTests = true;
            });
            # If the user hasn't set any pre/post commands, we don't want to
            # insert empty lines. This means that any existing users of crate2nix
            # don't get a spurious rebuild unless they set these explicitly.
            testCommand = pkgs.lib.concatStringsSep "\n" (
              pkgs.lib.filter (s: s != "") [
                testPreRun
                "$f $testCrateFlags 2>&1 | tee -a $out"
                testPostRun
              ]
            );
          in
          pkgs.stdenvNoCC.mkDerivation {
            name = "run-tests-${testCrate.name}";

            inherit (crate) src;

            inherit testCrateFlags;

            buildInputs = testInputs;

            buildPhase = ''
              set -e
              export RUST_BACKTRACE=1

              # build outputs
              testRoot=target/debug
              mkdir -p $testRoot

              # executables of the crate
              # we copy to prevent std::env::current_exe() to resolve to a store location
              for i in ${crate}/bin/*; do
                cp "$i" "$testRoot"
              done
              chmod +w -R .

              # test harness executables are suffixed with a hash, like cargo does
              # this allows to prevent name collision with the main
              # executables of the crate
              hash=$(basename $out)
              for file in ${drv}/tests/*; do
                f=$testRoot/$(basename $file)-$hash
                cp $file $f
                ${testCommand}
              done
            '';
          };
      in
      pkgs.runCommand "${crate.name}-linked"
        {
          inherit (crate) outputs crateName;
          passthru = (crate.passthru or { }) // {
            inherit test;
          };
        }
        (
          lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
            echo tested by ${test}
          ''
          + ''
            ${lib.concatMapStringsSep "\n" (output: "ln -s ${crate.${output}} ${"$"}${output}") crate.outputs}
          ''
        );

  # A restricted overridable version of builtRustCratesWithFeatures.
  buildRustCrateWithFeatures =
    { packageId
    , features ? rootFeatures
    , crateOverrides ? defaultCrateOverrides
    , buildRustCrateForPkgsFunc ? null
    , runTests ? false
    , testCrateFlags ? [ ]
    , testInputs ? [ ]
    , # Any command to run immediatelly before a test is executed.
      testPreRun ? ""
    , # Any command run immediatelly after a test is executed.
      testPostRun ? ""
    ,
    }:
    lib.makeOverridable
      (
        { features
        , crateOverrides
        , runTests
        , testCrateFlags
        , testInputs
        , testPreRun
        , testPostRun
        ,
        }:
        let
          buildRustCrateForPkgsFuncOverriden =
            if buildRustCrateForPkgsFunc != null then
              buildRustCrateForPkgsFunc
            else
              (
                if crateOverrides == pkgs.defaultCrateOverrides then
                  buildRustCrateForPkgs
                else
                  pkgs:
                  (buildRustCrateForPkgs pkgs).override {
                    defaultCrateOverrides = crateOverrides;
                  }
              );
          builtRustCrates = builtRustCratesWithFeatures {
            inherit packageId features;
            buildRustCrateForPkgsFunc = buildRustCrateForPkgsFuncOverriden;
            runTests = false;
          };
          builtTestRustCrates = builtRustCratesWithFeatures {
            inherit packageId features;
            buildRustCrateForPkgsFunc = buildRustCrateForPkgsFuncOverriden;
            runTests = true;
          };
          drv = builtRustCrates.crates.${packageId};
          testDrv = builtTestRustCrates.crates.${packageId};
          derivation =
            if runTests then
              crateWithTest
                {
                  crate = drv;
                  testCrate = testDrv;
                  inherit
                    testCrateFlags
                    testInputs
                    testPreRun
                    testPostRun
                    ;
                }
            else
              drv;
        in
        derivation
      )
      {
        inherit
          features
          crateOverrides
          runTests
          testCrateFlags
          testInputs
          testPreRun
          testPostRun
          ;
      };

  /*
    Returns an attr set with packageId mapped to the result of buildRustCrateForPkgsFunc
    for the corresponding crate.
  */
  builtRustCratesWithFeatures =
    { packageId
    , features
    , crateConfigs ? crates
    , buildRustCrateForPkgsFunc
    , runTests
    , makeTarget ? makeDefaultTarget
    ,
    }@args:
      assert (builtins.isAttrs crateConfigs);
      assert (builtins.isString packageId);
      assert (builtins.isList features);
      assert (builtins.isAttrs (makeTarget stdenv.hostPlatform));
      assert (builtins.isBool runTests);
      let
        rootPackageId = packageId;
        mergedFeatures = mergePackageFeatures (
          args
          // {
            inherit rootPackageId;
            target = makeTarget stdenv.hostPlatform // {
              test = runTests;
            };
          }
        );
        # Memoize built packages so that reappearing packages are only built once.
        builtByPackageIdByPkgs = mkBuiltByPackageIdByPkgs pkgs;
        mkBuiltByPackageIdByPkgs =
          pkgs:
          let
            self = {
              crates = lib.mapAttrs
                (
                  packageId: value: buildByPackageIdForPkgsImpl self pkgs packageId
                )
                crateConfigs;
              target = makeTarget pkgs.stdenv.hostPlatform;
              build = mkBuiltByPackageIdByPkgs pkgs.buildPackages;
            };
          in
          self;
        buildByPackageIdForPkgsImpl =
          self: pkgs: packageId:
          let
            features = mergedFeatures."${packageId}" or [ ];
            crateConfig' = crateConfigs."${packageId}";
            crateConfig = builtins.removeAttrs crateConfig' [
              "resolvedDefaultFeatures"
              "devDependencies"
            ];
            devDependencies = lib.optionals (runTests && packageId == rootPackageId) (
              crateConfig'.devDependencies or [ ]
            );
            dependencies = dependencyDerivations {
              inherit features;
              inherit (self) target;
              buildByPackageId =
                depPackageId:
                # proc_macro crates must be compiled for the build architecture
                if crateConfigs.${depPackageId}.procMacro or false then
                  self.build.crates.${depPackageId}
                else
                  self.crates.${depPackageId};
              dependencies = (crateConfig.dependencies or [ ]) ++ devDependencies;
            };
            buildDependencies = dependencyDerivations {
              inherit features;
              inherit (self.build) target;
              buildByPackageId = depPackageId: self.build.crates.${depPackageId};
              dependencies = crateConfig.buildDependencies or [ ];
            };
            dependenciesWithRenames =
              let
                buildDeps = filterEnabledDependencies {
                  inherit features;
                  inherit (self) target;
                  dependencies = crateConfig.dependencies or [ ] ++ devDependencies;
                };
                hostDeps = filterEnabledDependencies {
                  inherit features;
                  inherit (self.build) target;
                  dependencies = crateConfig.buildDependencies or [ ];
                };
              in
              lib.filter (d: d ? "rename") (hostDeps ++ buildDeps);
            # Crate renames have the form:
            #
            # {
            #    crate_name = [
            #       { version = "1.2.3"; rename = "crate_name01"; }
            #    ];
            #    # ...
            # }
            crateRenames =
              let
                grouped = lib.groupBy (dependency: dependency.name) dependenciesWithRenames;
                versionAndRename =
                  dep:
                  let
                    package = crateConfigs."${dep.packageId}";
                  in
                  {
                    inherit (dep) rename;
                    inherit (package) version;
                  };
              in
              lib.mapAttrs (name: builtins.map versionAndRename) grouped;
          in
          buildRustCrateForPkgsFunc pkgs (
            crateConfig
            // {
              src =
                crateConfig.src or (pkgs.fetchurl rec {
                  name = "${crateConfig.crateName}-${crateConfig.version}.tar.gz";
                  # https://www.pietroalbini.org/blog/downloading-crates-io/
                  # Not rate-limited, CDN URL.
                  url = "https://static.crates.io/crates/${crateConfig.crateName}/${crateConfig.crateName}-${crateConfig.version}.crate";
                  sha256 =
                    assert (lib.assertMsg (crateConfig ? sha256) "Missing sha256 for ${name}");
                    crateConfig.sha256;
                });
              extraRustcOpts =
                lib.lists.optional (targetFeatures != [ ])
                  "-C target-feature=${lib.concatMapStringsSep "," (x: "+${x}") targetFeatures}";
              inherit
                features
                dependencies
                buildDependencies
                crateRenames
                release
                ;
            }
          );
      in
      builtByPackageIdByPkgs;

  # Returns the actual derivations for the given dependencies.
  dependencyDerivations =
    { buildByPackageId
    , features
    , dependencies
    , target
    ,
    }:
      assert (builtins.isList features);
      assert (builtins.isList dependencies);
      assert (builtins.isAttrs target);
      let
        enabledDependencies = filterEnabledDependencies {
          inherit dependencies features target;
        };
        depDerivation = dependency: buildByPackageId dependency.packageId;
      in
      map depDerivation enabledDependencies;

  /*
    Returns a sanitized version of val with all values substituted that cannot
    be serialized as JSON.
  */
  sanitizeForJson =
    val:
    if builtins.isAttrs val then
      lib.mapAttrs (n: sanitizeForJson) val
    else if builtins.isList val then
      builtins.map sanitizeForJson val
    else if builtins.isFunction val then
      "function"
    else
      val;

  # Returns various tools to debug a crate.
  debugCrate =
    { packageId
    , target ? makeDefaultTarget stdenv.hostPlatform
    ,
    }:
      assert (builtins.isString packageId);
      let
        debug = rec {
          # The built tree as passed to buildRustCrate.
          buildTree = buildRustCrateWithFeatures {
            buildRustCrateForPkgsFunc = _: lib.id;
            inherit packageId;
          };
          sanitizedBuildTree = sanitizeForJson buildTree;
          dependencyTree = sanitizeForJson (buildRustCrateWithFeatures {
            buildRustCrateForPkgsFunc = _: crate: {
              "01_crateName" = crate.crateName or false;
              "02_features" = crate.features or [ ];
              "03_dependencies" = crate.dependencies or [ ];
            };
            inherit packageId;
          });
          mergedPackageFeatures = mergePackageFeatures {
            features = rootFeatures;
            inherit packageId target;
          };
          diffedDefaultPackageFeatures = diffDefaultPackageFeatures {
            inherit packageId target;
          };
        };
      in
      {
        internal = debug;
      };

  /*
    Returns differences between cargo default features and crate2nix default
    features.

    This is useful for verifying the feature resolution in crate2nix.
  */
  diffDefaultPackageFeatures =
    { crateConfigs ? crates
    , packageId
    , target
    ,
    }:
      assert (builtins.isAttrs crateConfigs);
      let
        prefixValues = prefix: lib.mapAttrs (n: v: { "${prefix}" = v; });
        mergedFeatures = prefixValues "crate2nix" (mergePackageFeatures {
          inherit crateConfigs packageId target;
          features = [ "default" ];
        });
        configs = prefixValues "cargo" crateConfigs;
        combined = lib.foldAttrs (a: b: a // b) { } [
          mergedFeatures
          configs
        ];
        onlyInCargo = builtins.attrNames (
          lib.filterAttrs (n: v: !(v ? "crate2nix") && (v ? "cargo")) combined
        );
        onlyInCrate2Nix = builtins.attrNames (
          lib.filterAttrs (n: v: (v ? "crate2nix") && !(v ? "cargo")) combined
        );
        differentFeatures = lib.filterAttrs
          (
            n: v:
              (v ? "crate2nix")
              && (v ? "cargo")
              && (v.crate2nix.features or [ ]) != (v."cargo".resolved_default_features or [ ])
          )
          combined;
      in
      builtins.toJSON {
        inherit onlyInCargo onlyInCrate2Nix differentFeatures;
      };

  /*
    Returns an attrset mapping packageId to the list of enabled features.

    If multiple paths to a dependency enable different features, the
    corresponding feature sets are merged. Features in rust are additive.
  */
  mergePackageFeatures =
    { crateConfigs ? crates
    , packageId
    , rootPackageId ? packageId
    , features ? rootFeatures
    , dependencyPath ? [ crates.${packageId}.crateName ]
    , featuresByPackageId ? { }
    , target
    , # Adds devDependencies to the crate with rootPackageId.
      runTests ? false
    , ...
    }@args:
      assert (builtins.isAttrs crateConfigs);
      assert (builtins.isString packageId);
      assert (builtins.isString rootPackageId);
      assert (builtins.isList features);
      assert (builtins.isList dependencyPath);
      assert (builtins.isAttrs featuresByPackageId);
      assert (builtins.isAttrs target);
      assert (builtins.isBool runTests);
      let
        crateConfig = crateConfigs."${packageId}" or (builtins.throw "Package not found: ${packageId}");
        expandedFeatures = expandFeatures (crateConfig.features or { }) features;
        enabledFeatures = enableFeatures (crateConfig.dependencies or [ ]) expandedFeatures;
        depWithResolvedFeatures =
          dependency:
          let
            inherit (dependency) packageId;
            features = dependencyFeatures enabledFeatures dependency;
          in
          {
            inherit packageId features;
          };
        resolveDependencies =
          cache: path: dependencies:
            assert (builtins.isAttrs cache);
            assert (builtins.isList dependencies);
            let
              enabledDependencies = filterEnabledDependencies {
                inherit dependencies target;
                features = enabledFeatures;
              };
              directDependencies = map depWithResolvedFeatures enabledDependencies;
              foldOverCache = op: lib.foldl op cache directDependencies;
            in
            foldOverCache (
              cache:
              { packageId, features }:
              let
                cacheFeatures = cache.${packageId} or [ ];
                combinedFeatures = sortedUnique (cacheFeatures ++ features);
              in
              if cache ? ${packageId} && cache.${packageId} == combinedFeatures then
                cache
              else
                mergePackageFeatures {
                  features = combinedFeatures;
                  featuresByPackageId = cache;
                  inherit
                    crateConfigs
                    packageId
                    target
                    runTests
                    rootPackageId
                    ;
                }
            );
        cacheWithSelf =
          let
            cacheFeatures = featuresByPackageId.${packageId} or [ ];
            combinedFeatures = sortedUnique (cacheFeatures ++ enabledFeatures);
          in
          featuresByPackageId
          // {
            "${packageId}" = combinedFeatures;
          };
        cacheWithDependencies = resolveDependencies cacheWithSelf "dep" (
          crateConfig.dependencies or [ ]
          ++ lib.optionals (runTests && packageId == rootPackageId) (crateConfig.devDependencies or [ ])
        );
        cacheWithAll = resolveDependencies cacheWithDependencies "build" (
          crateConfig.buildDependencies or [ ]
        );
      in
      cacheWithAll;

  # Returns the enabled dependencies given the enabled features.
  filterEnabledDependencies =
    { dependencies
    , features
    , target
    ,
    }:
      assert (builtins.isList dependencies);
      assert (builtins.isList features);
      assert (builtins.isAttrs target);

      lib.filter
        (
          dep:
          let
            targetFunc = dep.target or (features: true);
          in
          targetFunc { inherit features target; }
          && (!(dep.optional or false) || builtins.any (doesFeatureEnableDependency dep) features)
        )
        dependencies;

  # Returns whether the given feature should enable the given dependency.
  doesFeatureEnableDependency =
    dependency: feature:
    let
      name = dependency.rename or dependency.name;
      prefix = "${name}/";
      len = builtins.stringLength prefix;
      startsWithPrefix = builtins.substring 0 len feature == prefix;
    in
    feature == name || feature == "dep:" + name || startsWithPrefix;

  /*
    Returns the expanded features for the given inputFeatures by applying the
    rules in featureMap.

    featureMap is an attribute set which maps feature names to lists of further
    feature names to enable in case this feature is selected.
  */
  expandFeatures =
    featureMap: inputFeatures:
      assert (builtins.isAttrs featureMap);
      assert (builtins.isList inputFeatures);
      let
        expandFeaturesNoCycle =
          oldSeen: inputFeatures:
          if inputFeatures != [ ] then
            let
              # The feature we're currently expanding.
              feature = builtins.head inputFeatures;
              # All the features we've seen/expanded so far, including the one
              # we're currently processing.
              seen = oldSeen // {
                ${feature} = 1;
              };
              # Expand the feature but be careful to not re-introduce a feature
              # that we've already seen: this can easily cause a cycle, see issue
              # #209.
              enables = builtins.filter (f: !(seen ? "${f}")) (featureMap."${feature}" or [ ]);
            in
            [ feature ] ++ (expandFeaturesNoCycle seen (builtins.tail inputFeatures ++ enables))
          # No more features left, nothing to expand to.
          else
            [ ];
        outFeatures = expandFeaturesNoCycle { } inputFeatures;
      in
      sortedUnique outFeatures;

  /*
    This function adds optional dependencies as features if they are enabled
    indirectly by dependency features. This function mimics Cargo's behavior
    described in a note at:
    https://doc.rust-lang.org/nightly/cargo/reference/features.html#dependency-features
  */
  enableFeatures =
    dependencies: features:
      assert (builtins.isList features);
      assert (builtins.isList dependencies);
      let
        additionalFeatures = lib.concatMap
          (
            dependency:
              assert (builtins.isAttrs dependency);
              let
                enabled = builtins.any (doesFeatureEnableDependency dependency) features;
              in
              if (dependency.optional or false) && enabled then
                [ (dependency.rename or dependency.name) ]
              else
                [ ]
          )
          dependencies;
      in
      sortedUnique (features ++ additionalFeatures);

  /*
    Returns the actual features for the given dependency.

    features: The features of the crate that refers this dependency.
  */
  dependencyFeatures =
    features: dependency:
      assert (builtins.isList features);
      assert (builtins.isAttrs dependency);
      let
        defaultOrNil = if dependency.usesDefaultFeatures or true then [ "default" ] else [ ];
        explicitFeatures = dependency.features or [ ];
        additionalDependencyFeatures =
          let
            name = dependency.rename or dependency.name;
            stripPrefixMatch = prefix: s: if lib.hasPrefix prefix s then lib.removePrefix prefix s else null;
            extractFeature =
              feature:
              lib.findFirst (f: f != null) null (
                map (prefix: stripPrefixMatch prefix feature) [
                  (name + "/")
                  (name + "?/")
                ]
              );
            dependencyFeatures = lib.filter (f: f != null) (map extractFeature features);
          in
          dependencyFeatures;
      in
      defaultOrNil ++ explicitFeatures ++ additionalDependencyFeatures;

  # Sorts and removes duplicates from a list of strings.
  sortedUnique =
    features:
      assert (builtins.isList features);
      assert (builtins.all builtins.isString features);
      let
        outFeaturesSet = lib.foldl (set: feature: set // { "${feature}" = 1; }) { } features;
        outFeaturesUnique = builtins.attrNames outFeaturesSet;
      in
      builtins.sort (a: b: a < b) outFeaturesUnique;

  deprecationWarning =
    message: value:
    if strictDeprecation then
      builtins.throw "strictDeprecation enabled, aborting: ${message}"
    else
      builtins.trace message value;

  hasAtomicData = {
    # Architectures that always have a specific max atomic size
    standardArchs = builtins.fromJSON ''
      {"aarch64":128,"aarch64_be":128,"amdgcn":64,"arm64_32":128
      ,"arm64e":128,"arm64ec":128,"armeb":64,"armebv7r":64
      ,"armv6":64,"armv6k":32,"armv7":64,"armv7a":64,"armv7k":64
      ,"armv7r":64,"armv7s":64,"armv8r":64,"hexagon":32,"i386":64
      ,"i586":64,"i686":64,"loongarch64":64,"mips":32,"mips64":64
      ,"mips64el":64,"mipsisa32r6":32,"mipsisa32r6el":32,"mipsisa64r6":64
      ,"mipsisa64r6el":64,"nvptx64":64,"powerpc":32,"powerpc64":64
      ,"powerpc64le":64,"riscv32":32,"riscv32gc":32,"riscv32ima":32
      ,"riscv32imac":32,"riscv32imafc":32,"riscv64":64,"riscv64gc":64
      ,"riscv64imac":64,"s390x":128,"sparc":32,"sparc64":64
      ,"sparcv9":64,"thumbv7a":64,"thumbv7em":32,"thumbv7m":32
      ,"thumbv7neon":64,"thumbv8m.base":32,"thumbv8m.main":32
      ,"wasm32":64,"wasm32v1":64,"wasm64":64,"x86_64h":128}
    '';
    # Targets with non-standard architectures
    nonStandardTargets = builtins.fromJSON ''
      {"arm-linux-androideabi":32,"arm-unknown-linux-gnueabi":64
      ,"arm-unknown-linux-gnueabihf":64,"arm-unknown-linux-musleabi":64
      ,"arm-unknown-linux-musleabihf":64,"armv4t-unknown-linux-gnueabi":32
      ,"armv5te-unknown-linux-gnueabi":32,"armv5te-unknown-linux-musleabi":32
      ,"armv5te-unknown-linux-uclibceabi":32,"mipsel-mti-none-elf":32
      ,"mipsel-sony-psp":32,"mipsel-unknown-linux-gnu":32
      ,"mipsel-unknown-linux-musl":32,"mipsel-unknown-linux-uclibc":32
      ,"mipsel-unknown-netbsd":32,"mipsel-unknown-none":32
      ,"riscv32im-risc0-zkvm-elf":64,"riscv32imc-esp-espidf":32
      ,"riscv32imc-unknown-nuttx-elf":32,"thumbv6m-nuttx-eabi":32
      ,"x86_64-apple-darwin":128,"x86_64-apple-ios":128,"x86_64-apple-ios-macabi":128
      ,"x86_64-apple-tvos":128,"x86_64-apple-watchos-sim":128
      ,"x86_64-fortanix-unknown-sgx":64,"x86_64-linux-android":64
      ,"x86_64-pc-cygwin":64,"x86_64-pc-nto-qnx710":64,"x86_64-pc-nto-qnx710_iosock":64
      ,"x86_64-pc-nto-qnx800":64,"x86_64-pc-solaris":64,"x86_64-pc-windows-gnu":128
      ,"x86_64-pc-windows-gnullvm":128,"x86_64-pc-windows-msvc":128
      ,"x86_64-unikraft-linux-musl":64,"x86_64-unknown-dragonfly":64
      ,"x86_64-unknown-freebsd":64,"x86_64-unknown-fuchsia":64
      ,"x86_64-unknown-haiku":64,"x86_64-unknown-hermit":64
      ,"x86_64-unknown-hurd-gnu":64,"x86_64-unknown-illumos":64
      ,"x86_64-unknown-l4re-uclibc":64,"x86_64-unknown-linux-gnu":64
      ,"x86_64-unknown-linux-gnux32":64,"x86_64-unknown-linux-musl":64
      ,"x86_64-unknown-linux-none":64,"x86_64-unknown-linux-ohos":64
      ,"x86_64-unknown-netbsd":64,"x86_64-unknown-none":64
      ,"x86_64-unknown-openbsd":64,"x86_64-unknown-redox":64
      ,"x86_64-unknown-trusty":64,"x86_64-unknown-uefi":64
      ,"x86_64-uwp-windows-gnu":128,"x86_64-uwp-windows-msvc":128
      ,"x86_64-win7-windows-gnu":64,"x86_64-win7-windows-msvc":64
      ,"x86_64-wrs-vxworks":64}
    '';
  };

  #
  # crate2nix/default.nix (excerpt end)
  #{#
}
# -#}
