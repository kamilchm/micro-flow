let
  qemu = {
    targetEnv = "libvirtd";
    libvirtd.headless = true;
    libvirtd.memorySize = 1024;
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
          lib.foldl' (lines: i: lines + "localhost ${toString i.port}\n") "" cfg.instances
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

    networking.firewall.allowedTCPPorts = (map (i: i.port) cfg.instances) ++ [ 8080 8090 ];

    deployment = qemu;
  };

  defaultLayerCfg = {
    alpha = "1.4";
    beta = "20";
    lbAlgo = "roundRobin";
    #lbAlgo = "ewma";
    instances = [
      { port = 4444; }
      { port = 4445; }
      { port = 4446; }
    ];
  };

  layers = (map (cfg: defaultLayerCfg // cfg) [
    { name = "layer1"; nextHop = "http://layer2:8080/"; }
    { name = "layer2"; nextHop = "http://layer3:8080/"; }
    { name = "layer3"; nextHop = "http://layer4:8080/"; }
    { name = "layer4"; nextHop = "http://layer5:8080/"; }
    { name = "layer5"; }
  ]);

in
(builtins.listToAttrs (map (layer: {name = layer.name; value = microserver layer; }) layers)) // rec {
  network.description = "Microservices";

  client = { config, pkgs, ... }:
  let
    url = "http://layer1:8080?hops=4";
    qps = "2";
    concurrency = "60";
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

    deployment = qemu;
  };

  dashboard = { config, pkgs, ... }:
  let
    prometheus_ds = builtins.toFile "prometheus_ds.json" ''{
      "access": "proxy",
      "isDefault": true,
      "jsonData": {},
      "name": "prometheus",
      "type": "prometheus",
      "url": "http://dashboard:9090"
    }'';

    grafana_dashboard = ./Long_latency_tail.json;
  in
  {
    services.prometheus = {
      enable = true;
      globalConfig = {
        scrape_interval = "5s";
        scrape_timeout = "2s";
      };
      scrapeConfigs = (map (layer: {
        job_name = layer.name;
        static_configs = [{
          targets = map (i: "${layer.name}:${toString i.port}") layer.instances;
        }];
      }) layers)
      ++ [{
        job_name = "client";
        static_configs = [{
          targets = [ "client:8080" ];
        }];
      }];
    };

    services.grafana = {
      enable = true;
      addr = "0.0.0.0";
    };

    systemd.services.grafana_setup = {
      description = "default datasource and dashboard for Grafana";
      after = [ "grafana.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.curl ];
      script = ''
        curl -sX POST -u admin:admin -d @${prometheus_ds} \
          -H "Content-Type: application/json" \
          http://localhost:3000/api/datasources

        curl -sX POST -u admin:admin -d @${grafana_dashboard} \
          -H "Content-Type: application/json" \
          http://localhost:3000/api/dashboards/db
      '';

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    networking.firewall.allowedTCPPorts = [ 3000 9090 ];

    deployment = qemu;
  };
}
