let
  vbox =  {
    targetEnv = "virtualbox";
    virtualbox.memorySize = 1024; # megabytes
    virtualbox.vcpu = 1; # number of cpus
    virtualbox.headless = true;
  };

  microserver = cfg: 
  { config, pkgs, lib, ... }:
  { 
    nixpkgs.config = {
      allowUnfree = true;
      packageOverrides = _: {
        microservice = pkgs.buildGoPackage {
          name = "microservice";
          src = ./microservice;
          goPackagePath = "github.com/kamilchm/micro-flow/microservice";
        };

        linkerd = pkgs.stdenv.mkDerivation {
          name = "linkerd";
          src = pkgs.fetchurl {
            url = "https://github.com/linkerd/linkerd/releases/download/0.9.0/linkerd-0.9.0-exec";
            sha256 = "10caf15q959vmn03zrbmyhy9mk3v2ff8j8bls518yb4zj3kcda6g";
          };
          phases = [ "installPhase" "fixupPhase" ];
          buildInputs = with pkgs; [ oraclejre8 makeWrapper ];
          installPhase = ''
            mkdir -p $out/bin
            cp $src $out/bin/linkerd
            chmod +x $out/bin/linkerd
            wrapProgram $out/bin/linkerd --prefix JAVA_HOME : ${pkgs.oraclejre8}
          '';
        };
      };
    };

    environment.etc = [
      { source = pkgs.writeText "app" (
          lib.foldl' (lines: cfg: lines + "localhost ${toString cfg.port}\n") "" cfg.instances
        );
        target = "linkerd/disco/app";
      }
    ];

    systemd.services = {
      linkerd =
      let
        cfgFile = pkgs.writeText "linkerd.yaml" ''
          namers:
            - kind: io.l5d.fs
              rootDir: /etc/linkerd/disco

          routers:
          - protocol: http
            servers:
            - port: 8080
              ip: 0.0.0.0
            # route all traffic to service identified in service discovery as "app"
            dtab: >-
              /svc => /#/io.l5d.fs/app;
            responseClassifier:
              kind: io.l5d.retryableRead5XX
            client:
              loadBalancer:
                kind: ${cfg.lbAlgo}
                decayTimeMs: 10000
          admin:
            ip: 0.0.0.0
            port: 8090
        '';
      in
      {
        description = "Linkerd";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          ExecStart = "${pkgs.linkerd}/bin/linkerd ${cfgFile}";
          Restart = "always";
        };
      };
    } // lib.listToAttrs (map (i:
      let
        portStr = toString i.port;
      in {
      name = "microservice_${portStr}";
      value = {
        description = "Microservice ${portStr}";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          ExecStart = ''
            ${pkgs.microservice}/bin/microservice \
              ${lib.optionalString (cfg ? alpha) "-alpha=${cfg.alpha}"} \
              ${lib.optionalString (cfg ? beta) "-beta=${cfg.beta}"} \
              ${lib.optionalString (i ? errors) "-errors=${i.errors}"} \
              ${lib.optionalString (i ? speed) "-speed=${i.speed}"} \
              ${lib.optionalString (cfg ? nextHop) "-next-hop=${cfg.nextHop}"} \
              -port ${toString portStr}
            '';
        };
      };
    }) cfg.instances);

    networking.firewall.allowedTCPPorts = (map (cfg: cfg.port) cfg.instances) ++ [ 8080 8090 ];

    deployment = vbox;
  };

  #
  # TEST CONFIGURATIONS
  #

  testFiveHopsLayer = {
    alpha = "3.5";
    beta = "34.6";
    lbAlgo = "roundRobin";
    instances = [
      { port = 4444; }
      { port = 4445; }
      { port = 4446; }
      { port = 4447; }
      { port = 4448; }
      { port = 4449; }
    ];
  };

  layer1Config = testFiveHopsLayer // { nextHop = "http://layer2:8080/"; };
  layer2Config = testFiveHopsLayer // { nextHop = "http://layer3:8080/"; };
  layer3Config = testFiveHopsLayer // { nextHop = "http://layer4:8080/"; };
  layer4Config = testFiveHopsLayer // { nextHop = "http://layer5:8080/"; };
  layer5Config = testFiveHopsLayer;
in
rec {
  network.description = "Microservices";

  layer1 = microserver layer1Config;
  layer2 = microserver layer2Config;
  layer3 = microserver layer3Config;
  layer4 = microserver layer4Config;
  layer5 = microserver layer5Config;

  client = { config, pkgs, ... }:
  let
    url = "http://layer1:8080?hops=5";
    qps = "1";
    concurrency = "50";
  in
  {
    nixpkgs.config = {
      packageOverrides = _: {
        slow_cooker = pkgs.buildGoPackage rec {
          name = "slow_cooker-${version}";
          version = "1.1.0";
          src = pkgs.fetchFromGitHub {
            owner = "BuoyantIO";
            repo = "slow_cooker";
            rev = version;
            sha256 = "18yjgg6sqmg1q3jb5y1psqfqn4qizk8fi6ah44vcai9sfbn6s5sg";
          };
          goPackagePath = "github.com/buoyantio/slow_cooker";
        };
      };
    };

    systemd.services.slow_cooker = {
      description = "Slow Cooker";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.slow_cooker}/bin/slow_cooker -qps=${qps} -concurrency ${concurrency} -metric-addr=:8080 ${url}";
      };
    };

    networking.firewall.allowedTCPPorts = [ 8080 ];

    deployment = vbox;
  };

  dashboard = { config, pkgs, ... }:
  {
    services.prometheus = {
      enable = true;
      globalConfig = {
        scrape_interval = "5s";
        scrape_timeout = "2s";
      };
      scrapeConfigs = [
      {
        job_name = "layer1";
        static_configs = [{
          targets = map (c: "layer1:${toString c.port}") layer1Config.instances;
        }];
      }
      {
        job_name = "layer2";
        static_configs = [{
          targets = map (c: "layer2:${toString c.port}") layer2Config.instances;
        }];
      }
      {
        job_name = "layer3";
        static_configs = [{
          targets = map (c: "layer3:${toString c.port}") layer3Config.instances;
        }];
      }
      {
        job_name = "layer4";
        static_configs = [{
          targets = map (c: "layer4:${toString c.port}") layer4Config.instances;
        }];
      }
      {
        job_name = "layer5";
        static_configs = [{
          targets = map (c: "layer5:${toString c.port}") layer5Config.instances;
        }];
      }
      {
        job_name = "client";
        static_configs = [{
          targets = [ "client:8080" ];
        }];
      }
      ];
    };

    services.grafana = {
      enable = true;
      addr = "0.0.0.0";
    };

    networking.firewall.allowedTCPPorts = [ 3000 9090 ];

    deployment = vbox;
  };
}
