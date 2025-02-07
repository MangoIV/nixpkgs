# GitLab {#module-services-gitlab}

GitLab is a feature-rich git hosting service.

## Prerequisites {#module-services-gitlab-prerequisites}

The `gitlab` service exposes only an Unix socket at
`/run/gitlab/gitlab-workhorse.socket`. You need to
configure a webserver to proxy HTTP requests to the socket.

For instance, the following configuration could be used to use nginx as
frontend proxy:
```nix
{
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts."git.example.com" = {
      enableACME = true;
      forceSSL = true;
      locations."/".proxyPass = "http://unix:/run/gitlab/gitlab-workhorse.socket";
    };
  };
}
```

## Configuring {#module-services-gitlab-configuring}

GitLab depends on both PostgreSQL and Redis and will automatically enable
both services. In the case of PostgreSQL, a database and a role will be
created.

The default state dir is `/var/gitlab/state`. This is where
all data like the repositories and uploads will be stored.

A basic configuration with some custom settings could look like this:
```nix
{
  services.gitlab = {
    enable = true;
    databasePasswordFile = "/var/keys/gitlab/db_password";
    initialRootPasswordFile = "/var/keys/gitlab/root_password";
    https = true;
    host = "git.example.com";
    port = 443;
    user = "git";
    group = "git";
    smtp = {
      enable = true;
      address = "localhost";
      port = 25;
    };
    secrets = {
      dbFile = "/var/keys/gitlab/db";
      secretFile = "/var/keys/gitlab/secret";
      otpFile = "/var/keys/gitlab/otp";
      jwsFile = "/var/keys/gitlab/jws";
    };
    extraConfig = {
      gitlab = {
        email_from = "gitlab-no-reply@example.com";
        email_display_name = "Example GitLab";
        email_reply_to = "gitlab-no-reply@example.com";
        default_projects_features = {
          builds = false;
        };
      };
    };
  };
}
```

If you're setting up a new GitLab instance, generate new
secrets. You for instance use
`tr -dc A-Za-z0-9 < /dev/urandom | head -c 128 > /var/keys/gitlab/db` to
generate a new db secret. Make sure the files can be read by, and
only by, the user specified by
[services.gitlab.user](#opt-services.gitlab.user). GitLab
encrypts sensitive data stored in the database. If you're restoring
an existing GitLab instance, you must specify the secrets secret
from `config/secrets.yml` located in your GitLab
state folder.

When `incoming_mail.enabled` is set to `true`
in [extraConfig](#opt-services.gitlab.extraConfig) an additional
service called `gitlab-mailroom` is enabled for fetching incoming mail.

Refer to [](#ch-options) for all available configuration
options for the [services.gitlab](#opt-services.gitlab.enable) module.

### Container registry {#module-services-gitlab-configuring-container-registry}

GitLab Container registry support is built upon GitLab's
[`container-registry`][container-registry] registry implementation
(`pkgs.gitlab-container-registry`).
This is an HTTP service typically served on port 5000 which runs alongside
GitLab and is configured via the options in `services.gitlab.registry`.
Typically this service will be exposed to the internet via reverse proxy.

Authentication is handled by JWT, the keys of which must be shared between
GitLab and the registry.

A simple registry configuration using `nginx` for reverse proxying might look
like:

```nix
{
  services.gitlab.registry = {
    enable = true;
    keyFile = "/var/lib/gitlab-docker-registry/registry-auth.key";
    certFile = "/var/lib/gitlab-docker-registry/registry-auth.crt";
    externalAddress = "registry.my-domain.org";
    externalPort = 443;

    -- This is unnecessary if system.stateVersion >= 23.11
    package = pkgs.gitlab-container-registry;
  };

  services.nginx = {
    virtualHosts."registry.my-domain.org" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://localhost:5000";
      };
      -- Images tend to be large, disable maximum body size
      extraConfig = ''
        client_max_body_size 0;
      '';
    };
  };
}
```

[container-registry]: https://gitlab.com/gitlab-org/container-registry/

## Maintenance {#module-services-gitlab-maintenance}

### Backups {#module-services-gitlab-maintenance-backups}

Backups can be configured with the options in
[services.gitlab.backup](#opt-services.gitlab.backup.keepTime). Use
the [services.gitlab.backup.startAt](#opt-services.gitlab.backup.startAt)
option to configure regular backups.

To run a manual backup, start the `gitlab-backup` service:
```ShellSession
$ systemctl start gitlab-backup.service
```

### Rake tasks {#module-services-gitlab-maintenance-rake}

You can run GitLab's rake tasks with `gitlab-rake`
which will be available on the system when GitLab is enabled. You
will have to run the command as the user that you configured to run
GitLab with.

A list of all available rake tasks can be obtained by running:
```ShellSession
$ sudo -u git -H gitlab-rake -T
```

### Migrating container metadata to database {#module-services-gitlab-maintenance-registry-database}

GitLab is gradually [moving towards][epic5521] tracking of container registry
metadata in a dedicated database. This can be configured in NixOS via the
options in `services.gitlab.registry.database`.

Documentation on the migration path for an existing installation can be found
in the [GitLab documentation][registry-migration]. In this section we will
outline the three-step migration process as it would be performed in a NixOS
installation.

1. Create a PostgreSQL database for use by container metadata:
   ```bash
   $ sudo -u postgres psql
   postgres=# create role gitlab_registry with password 'ha8iJ#MIMDKKonwnbd' login;
   CREATE ROLE
   postgres=# create database gitlab_registry with owner gitlab_registry;
   CREATE DATABASE
   ```

2. Configure the database but leave support disabled with, for instance,

   ```nix
   {
     services.gitlab.registry.database = {
       enable = false;
       host = "db-server.domain";
       port = 5432;
       user = "db-user";
       passwordFile = "/var/secrets/gitlab-registry-database-password";
       databaseName = "gitlab-registry";
     };
   }
   ```

3. Apply the schema migrations and begin the initial import step:

   ```bash
   $ nix run nixpkgs#gitlab-container-registry -- database migrate up
   $ nix shell nixpkgs#gitlab-container-registry -c \
       sudo -u git registry import --step-one
   ```

4. Place the registry in read-only mode in preparation for
   the second import step:

   ```nix
   {
     services.dockerRegistry.extraConfig.maintenance.readonly.enabled = true;
   }
   ```

5. Initiate the step two import:

   ```bash
   $ nix shell nixpkgs#gitlab-container-registry -c \
       sudo -u git registry import --step-two
   ```

6. Set `services.gitlab.registry.database.enable` to `true` and return the
   registry to read-write mode.

7. Complete the migration by running the step three import:

   ```bash
   $ nix shell nixpkgs#gitlab-container-registry -c \
       sudo -u git registry import --step-three
   ```

[registry-migration]: https://docs.gitlab.com/ee/administration/packages/container_registry_metadata_database.html
[epic5521]: https://gitlab.com/groups/gitlab-org/-/epics/5521

