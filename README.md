# NVIDIA Nemotron NIMs on Azure Container Apps (serverless A100 / T4)

![Azure Container Apps](https://img.shields.io/badge/Azure-Container%20Apps-0078D4?logo=microsoftazure&logoColor=white)
![Bicep](https://img.shields.io/badge/IaC-Bicep-3F6EB5)
![Terraform](https://img.shields.io/badge/IaC-Terraform-844FBA?logo=terraform&logoColor=white)
![NVIDIA NIM](https://img.shields.io/badge/NVIDIA-NIM-76B900?logo=nvidia&logoColor=white)
![GPU](https://img.shields.io/badge/serverless%20GPU-A100%20%7C%20T4-76B900?logo=nvidia&logoColor=white)

Install guide for the 5 NVIDIA Nemotron container apps and their Container Apps environment.
The region, subscription and resource group are **never hardcoded**: you pass them at deploy time (see §5 and §6).
For this POC every app is reached on its own default FQDN (`https://<app-name>.<environment-default-domain>`), printed in the deployment outputs and listed in §7.

```text
deploy-nvidia/
├─ README.md                      <- this guide
├─ scripts/create-share-folders.ps1   <- manual alternative to the folder creation done by the IaC
├─ conf/default.conf              <- nginx config of the nemotron-nano-12b-v2-vl sidecar (§6.1)
├─ bicep/
│  ├─ main.bicep / main.bicepparam
│  ├─ modules/  environment.bicep  storage.bicep  private-endpoint.bicep
│  └─ apps/     one file per container app
└─ terraform/
   ├─ providers.tf variables.tf main.tf environment.tf private-endpoint.tf outputs.tf   <- environment.tf and the nano app use azapi (see §6, §6.1)
   └─ app-*.tf                    <- one file per container app
```

---

## 1. What gets deployed

| App | Model | Workload profile | Why | CPU / RAM | Image registry | Replicas |
|---|---|---|---|---|---|---|
| `nemotron-nano-12b-v2-vl` | 12B vision-language (vLLM) | **A100** (`Consumption-GPU-NC24-A100`) | Needs the 80 GB card; uses the whole node, shared with an **nginx sidecar** (§6.1) | 22 + 2 / 212 + 8 Gi | `nvcr.io` (NGC key) | fixed 1 |
| `nemotron-graphic-elements-v1` | chart/graphic detection | **T4** (`Consumption-GPU-NC8as-T4`) | Small detection model; fits a 16 GB T4 | 8 / 56 Gi | `nvcr.io` (NGC key) | fixed 1 |
| `nemotron-ocr-v1` | OCR | **T4** | Runs healthy on T4 today; small model | 8 / 56 Gi | `nvcr.io` (NGC key) | fixed 1 |
| `nemotron-page-elements-v3` | page layout detection (~1 GiB GPU memory) | **T4** | Tiny model; custom image makes it T4-compatible | 8 / 56 Gi | `containerdemosdec.azurecr.io` (**anonymous pull**) | fixed 1 |
| `nemotron-table-structure-v1` | table structure detection (~1 GiB GPU memory) | **T4** | Same as above | 8 / 56 Gi | `containerdemosdec.azurecr.io` (**anonymous pull**) | fixed 1 |

**Scaling is disabled**: every app has `minReplicas = 1` and `maxReplicas = 1` and no scale rules (no HTTP/KEDA scaler, no scale-to-zero).
Total GPU footprint is therefore constant: **1 × A100 + 4 × T4**, always allocated and billed.

Serverless GPU facts that drive the sizing (Microsoft Learn, *Workload profiles* / *Serverless GPUs*):

- **T4** = 8 vCPU / 56 GiB / 1 GPU per replica; **A100** = 24 vCPU / 220 GiB / 1 GPU per replica. Memory and CPU are per replica, one replica = one whole GPU. No fractional or multi-GPU replicas.
- Only the **first container** of an app sees the GPU. Several apps can share one profile, but each replica needs its own GPU.
- Serverless GPUs require a **workload-profiles environment** (not Consumption-only) in a region that offers serverless GPUs (see *Serverless GPUs* on Microsoft Learn for the current region list).
- Scale-to-zero is supported by the platform but is **not used** here (fixed 1 replica); the first start still includes the image pull and model load.

The environment defines three profiles: `Consumption` (default), `A100-Profile`, `T4-Profile`.
(The live environment calls them `GPU` and `T4-Profile`; the IaC uses clearer names.)

> [!TIP]
> **Rule of thumb for choosing a profile:** model ≤ ~16 GB of GPU memory → T4 (much cheaper). LLM/VLM that needs more memory → A100.
>
> Only the nano VLM is on A100. The stock NIM images for graphic-elements and OCR list A100-class GPUs in NVIDIA's support matrix, not T4 (OCR is known to run on T4 in your live environment; graphic-elements on T4 is a choice to **validate** on first start).
> If either fails to start on T4, change its profile to `A100-Profile` (one line: `main.bicep` / the `workload_profile_name` in its `.tf`).

---

## 2. Prerequisites

1. **Tools**: Azure CLI ≥ 2.60 (`az bicep install`), Terraform ≥ 1.6 (for the Terraform path), PowerShell.
2. **Permissions**: Contributor on the resource group.
3. **GPU quota**: serverless GPU quota is granted per subscription/region and per GPU type (Azure portal → *Quotas* → *Container Apps*, or a support request).
   You need quota for **1 A100 and 4 T4 GPUs** (one per app, since scaling is fixed at 1 replica).
4. **NGC API key** from <https://org.ngc.nvidia.com/setup/api-keys> (with access to the NIM catalog). It is passed at deploy time only (env var), never stored in files.
5. **Custom image** `containerdemosdec.azurecr.io/nvidia/nemotron-object-detection:custom`, used by *page-elements-v3* and *table-structure-v1* (it downloads the model weights from NGC at first start into `/model`).
   The ACR and the image are provided and maintained by **another team/project**; this guide only consumes them (nothing here builds, pushes or configures that registry).
6. Resource providers registered: `Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.Storage` (`Microsoft.Network` for the private option).

---

## 3. Registries and authentication

Two registries are involved, with different authentication:

| Registry | Used by | Auth | Details |
|---|---|---|---|
| `nvcr.io` (NVIDIA NGC) | nano-12b-v2-vl, graphic-elements-v1, ocr-v1 | **Username `$oauthtoken` + NGC API key as password** | NGC offers no managed-identity option. The key is stored as an app **secret** `ngc-api-key`; the registry entry uses `passwordSecretRef: ngc-api-key`. The same secret feeds the `NGC_API_KEY` env var (NIM uses it to download its model at startup). |
| `containerdemosdec.azurecr.io` (ACR owned by another team, **treated as public**) | page-elements-v3, table-structure-v1 | **Anonymous pull – no credentials** | The apps have no `registries` entry and no identity. The registry is managed by the other team; nothing is configured on it by this guide. |

Notes:
- **One key, three uses.** You give the template a single value: `ngcApiKey` (Bicep, read from `$env:NGC_API_KEY` by `main.bicepparam`) or `ngc_api_key` (Terraform, `TF_VAR_ngc_api_key`). Each app turns it into one app secret `ngc-api-key`, which is used (a) as the `nvcr.io` registry password (username `$oauthtoken`), only for the three NIM apps, and (b) as the `NGC_API_KEY` env var, for all five apps. It is a `@secure()` / `sensitive` value, so it is not shown in deployment outputs or plan output.
- **Check the key before deploying** (HTTP 200 and a token means the key can pull that image; a 401 is exactly what a missing/invalid key gives as `Failed to provision revision ... unexpected status code 401 Unauthorized` on the app):
  ```powershell
  $h = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('$oauthtoken:' + $env:NGC_API_KEY)) }
  Invoke-WebRequest 'https://nvcr.io/proxy_auth?scope=repository:nim/nvidia/nemotron-ocr-v1:pull' -Headers $h -UseBasicParsing | Select-Object StatusCode
  ```
- The two detection apps have `NGC_API_KEY` too, but no `nvcr.io` registry entry: their image comes from the ACR and only the *runtime* download of weights talks to NGC.
- Pin image tags (`:latest` is used today). NIM images are large; a floating tag makes every cold start/rollout non-reproducible.

> [!IMPORTANT]
> The live apps were configured with the NGC key as a **plain-text environment variable**, visible to anyone who can read the apps' configuration. The IaC uses secrets + `secretRef` instead. **Rotate the old key** in NGC after migrating, and never commit a key to this repository.

---

## 4. Volumes (Azure Files)

All apps share **one SMB file share** (`containers`, FileStorage premium, 1 TiB, in the **new** storage account whose name you choose) so that model weights and caches survive restarts and redeployments.

How it is wired, in 3 layers. **The deployment order is what makes it work: layers 1 and 2 (account, share, folders, environment link) are created by the IaC *before* any app, so nothing has to be prepared by hand.**

1. **Storage account + share + folders**
   - Account and share: `modules/storage.bicep` / `main.tf`.
   - The `subPath` **folders** are created in the same step:
     - **Terraform**: `azurerm_storage_share_directory` (native resource; parents first, then children). It talks to the storage data plane, so the machine running Terraform must be able to reach the account's file endpoint with the account key.
     - **Bicep**: ARM has **no resource type for folders inside a file share**, so `modules/storage.bicep` runs a `Microsoft.Resources/deploymentScripts` (Azure CLI in a short-lived container, using the account key) right after the share. The environment and the apps only start after this module has finished. The script service creates a temporary storage account and container instance in the resource group (removed after success) and needs key-based access to be allowed on your storage account.
2. **Environment storage link** named `shared-volume` (`Microsoft.App/managedEnvironments/storages`, `azurerm_container_app_environment_storage`) – holds the account name, key, share name and `ReadWrite`.
3. **Per-app `volumes` + `volumeMounts`**: the app declares a volume of type `AzureFile` pointing at `storageName: shared-volume`, then mounts it with a **`subPath`**, so each app (and each purpose) uses its own folder on the same share.
   Mount options are `dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks` (NIM containers run as UID 1000).

Every app also gets an `EmptyDir` volume `dshm` mounted on `/dev/shm` (shared memory for PyTorch/TensorRT, ephemeral).

| App | Volume name | subPath on the share | Mount path | Purpose |
|---|---|---|---|---|
| nano-12b-v2-vl | `cache` | `nano-12b-v2-vl/cache` | `/opt/nim/.cache` | NIM model cache (~tens of GB, avoids re-download) |
| graphic-elements-v1 | `storage` | `graphic-elements-v1/cache` | `/opt/nim/.cache` | NIM model cache |
| graphic-elements-v1 | `storage` | `graphic-elements-v1/torch` | `/tmp/inductor` | TorchInductor compile cache |
| ocr-v1 | `nim-cache` | `ocr-v1` | `/opt/nim/.cache` | NIM model cache |
| page-elements-v3 | `storage` | `page-elements-v3/weight` | `/model` | Model weights (`NIM_ENGINE_MODEL_PATH=/model/page-elements`) |
| page-elements-v3 | `storage` | `page-elements-v3/cache` | `/opt/cache` | Runtime cache |
| table-structure-v1 | `storage` | `table-structure-v1/weight` | `/model` | Model weights (`/model/table-structure`) |
| table-structure-v1 | `storage` | `table-structure-v1/cache` | `/opt/cache` | Runtime cache |

---

## 5. Deploy with Bicep

```powershell
cd bicep
$sub = '<subscription-id>'; $rg = '<resource-group>'            # chosen at deploy time, not stored in the templates
$env:NGC_API_KEY          = '<your NGC API key>'               # read by main.bicepparam; never committed
$env:LOCATION             = '<azure-region>'                   # region offering serverless A100/T4 GPUs
$env:STORAGE_ACCOUNT_NAME = '<unique-storage-account-name>'    # globally unique; must not be an existing account

az account set --subscription $sub
az group create -n $rg -l $env:LOCATION                         # skip if the resource group already exists
az storage account check-name -n $env:STORAGE_ACCOUNT_NAME --query "{ok:nameAvailable,reason:reason}" -o json

az deployment group what-if -g $rg -f main.bicep -p main.bicepparam
az deployment group create  -g $rg -f main.bicep -p main.bicepparam
```

Order of resources (enforced by dependencies): storage account → share → **folders (deployment script)** → environment (+ Log Analytics + storage link) → 5 apps (in parallel). No manual step is needed between them, and every app (including `nemotron-nano-12b-v2-vl` with its nginx sidecar, §6.1) is created complete, with its ingress, in one deployment.

Validated: `az bicep build` (0 warnings) and `az deployment group validate` (Succeeded).
`location` and `storageAccountName` are **required parameters** with no default; subscription and resource group are the deployment target. `environmentName` / `logAnalyticsName` have generic defaults (`nim-gpu-env`, `nim-gpu-logs`) you can override.
> [!NOTE]
> Storage account names are unique across all of Azure, so pick one that does not exist yet. The new account defaults to `Premium_LRS`; override `storageSkuName` (e.g. `PremiumV2_LRS`) for another file-share tier.

> [!WARNING]
> **Existing environment in the same resource group:** if the resource group already contains a Container Apps environment with different names,
> a deployment creates a **second environment with its own GPU replicas** – it can exhaust GPU quota and doubles cost.
> Deploy into a fresh resource group, or reuse the existing environment/app names to update in place.

---

## 6. Deploy with Terraform

```powershell
cd terraform
$env:TF_VAR_subscription_id       = '<subscription-id>'
$env:TF_VAR_resource_group_name   = '<existing-resource-group>'
$env:TF_VAR_location              = '<azure-region>'
$env:TF_VAR_storage_account_name  = '<unique-storage-account-name>'   # globally unique; must not be an existing account
$env:TF_VAR_ngc_api_key           = '<your NGC API key>'
az login

terraform init
terraform plan -out tfplan
terraform apply tfplan
```

- Order (enforced by `depends_on`): storage account → share → **folders (`azurerm_storage_share_directory`)** → environment storage link → 5 apps. No manual step in between.
- Uses `azurerm ~> 4.40` for everything **except the Container Apps environment and the `nemotron-nano-12b-v2-vl` app**, which use `azapi ~> 2.4` (direct ARM calls, the same API as Bicep). Reasons (found while testing): `azurerm_container_app_environment` always sends `MinimumCount` for workload profiles and the platform rejects it for serverless GPU profiles (`WorkloadProfilePropertyNotSupported ... Consumption_GPU_NC24_A100`, azurerm issue #31763); and `azurerm_container_app` cannot mount a secret as a file with a chosen name (needed for the nginx config, §6.1). `terraform init` installs both providers; nothing else changes for you.
- Tested end to end (real NGC key, one `terraform apply`, and separately the Bicep module): all five apps are created complete with their ingress in a single step; the four public apps return `{"ready": true}`, and `nemotron-nano-12b-v2-vl` answers through nginx (`/v1/health/ready`, `/v1/models` and a chat completion) once the model has loaded.
- `subscription_id`, `resource_group_name`, `location` and `storage_account_name` are **required variables** with no default (set them with `TF_VAR_*`, `-var`, or `terraform.tfvars` – see `terraform.tfvars.example`).
- The resource group is a **data source** (must already exist). Everything else is created.
- `storage_account_name` is validated as 3-24 lowercase letters/digits; names are unique across Azure, so pick one that does not exist yet.
- The `conf/` folder must stay next to `terraform/` (the nano app reads `../conf/default.conf`).
- Remote state: add a `backend "azurerm"` block; state contains the storage key and NGC key – protect it.

---

### 6.1 `nemotron-nano-12b-v2-vl`: nginx sidecar (everything is set at creation)

This app has **two containers in the same replica** (they share the network, so nginx reaches the NIM on `127.0.0.1:8000`):

| Container | Image | Role | CPU / RAM |
|---|---|---|---|
| `nemotron-nano-12b-v2-vl` (first) | `nvcr.io/nim/nvidia/nemotron-nano-12b-v2-vl:latest` | NIM / vLLM server on **:8000**. It must stay the **first** container: only the first container of an app gets the GPU. | 22 / 212 Gi |
| `nginx` | `docker.io/nginx:stable-alpine` (`nginxImage` / `nginx_image`) | Reverse proxy on **:8080** → `127.0.0.1:8000` | 2 / 8 Gi |

The two add up to the 24 vCPU / 220 GiB of one A100 replica (the nginx share is taken from the NIM container, which is why it is 22 / 212 instead of 24 / 220).

> [!NOTE]
> **Why the sidecar:** the 12B model takes a very long time to load. With the ingress pointing at the NIM (port 8000) the platform probes a port that is not listening yet, and the deployment fails. With nginx the **ingress and the liveness/readiness probes target port 8080**, which answers as soon as nginx starts, so the app is created in a single step **with its ingress** – there is no second phase. Until the model has loaded, requests through the FQDN get a `502` from nginx; afterwards they are proxied to the NIM.

| Setting | Value |
|---|---|
| Ingress | external, `targetPort: 8080` |
| Liveness / Readiness probes (NIM container) | TCP **8080** (same delays, periods, timeouts and thresholds as before: 60 s / 60 s / 10 s, thresholds 30 and 48) |
| Startup probe (NIM container) | unchanged: TCP 8000, 60 s period, threshold 240 |
| nginx config | `conf/default.conf`, stored as the app secret **`nginx-conf`** |
| Volume `nginx-conf` | type `Secret`, secret `nginx-conf`, file path **`default.conf`** |
| Mount | in the `nginx` container at `/etc/nginx/conf.d` (so the file is `/etc/nginx/conf.d/default.conf`) |
| Other volumes / mounts | unchanged (`dshm` on `/dev/shm`, share `cache` on `/opt/nim/.cache`) |

**The nginx configuration** ([conf/default.conf](conf/default.conf)) listens on 8080 and proxies to `127.0.0.1:8000`, with `client_max_body_size 500m` (vision-language requests carry base64 images; the 1 MB default would return `413`), `proxy_buffering off` (streamed responses) and 600 s read/send timeouts. Edit that file and redeploy to change it: both Bicep (`loadTextContent('../../conf/default.conf')`) and Terraform (`file("${path.module}/../conf/default.conf")`) read it at deploy time, so keep the `conf/` folder next to `bicep/` and `terraform/`.

Implementation notes:
- **Bicep:** `bicep/apps/nemotron-nano-12b-v2-vl.bicep`. The config is not sensitive; it is only an app secret because a Secret volume is the way to mount it as a file, so one linter rule (`use-secure-value-for-secure-inputs`) is disabled on that line.
- **Terraform:** the nano app is an **`azapi_resource`** (like the environment), not `azurerm_container_app`: the azurerm `volume` block cannot set the file path of a secret, and a Secret volume would mount **all** app secrets (including `ngc-api-key`) as files into the nginx container. A side benefit: azapi is not limited by azurerm's `failure_count_threshold ≤ 10`, so the probes are exactly the Bicep values.
- **Docker Hub:** `nginx:stable-alpine` is pulled anonymously from Docker Hub, which can be rate limited. If that matters, mirror it into a registry you control and set `nginxImage` / `nginx_image` (add registry credentials or an identity for that registry).
- The old two-phase procedure (deploy without ingress, then enable it) and its files (`enable-nano-ingress.*`, `phase2-nano-ingress.tfvars`, `enableNanoIngress` / `enable_nano_ingress`) no longer exist.

> [!CAUTION]
> **Troubleshooting – replica in `CrashLoopBackOff` with `RuntimeError: No CUDA GPUs are available`** (seen once in testing, with identical configuration that worked on another run). The replica was placed on a node where the GPU was not exposed to the container; the confusing `Could not import module 'ProcessorMixin'` error that follows is only a side effect. It is a platform placement issue, not a template problem. Restart the revision to get a new replica on another node:
>
> ```powershell
> az containerapp revision restart -g $rg -n nemotron-nano-12b-v2-vl --revision <revision-name>
> ```
>
> The same can happen to any GPU app. Note that `az containerapp logs show` mixes the logs of all replicas, so a stale crashing replica can make a healthy one look broken; pass `--replica <name> --container <app-name>` to read one replica. On Windows set `$env:PYTHONUTF8 = '1'` first, otherwise the CLI fails with a `charmap` encoding error on NIM's log characters.

---

## 7. Test

```powershell
# URLs of all apps (the FQDN of each container app)
az containerapp list -g $rg --query "[].{app:name, fqdn:properties.configuration.ingress.fqdn}" -o table

$fqdn = az containerapp show -g $rg -n nemotron-ocr-v1 --query properties.configuration.ingress.fqdn -o tsv
curl "https://$fqdn/v1/health/ready"          # NIM readiness
curl "https://$fqdn/v1/models"                 # VLM: lists the model id to use in /v1/chat/completions
az containerapp logs show -g $rg -n nemotron-ocr-v1 --follow
az containerapp replica list -g $rg -n nemotron-ocr-v1 -o table
```

Each app always keeps one replica, so there is no scale-from-zero delay; right after a deployment or restart, wait for the model to load before the first request.
`nemotron-nano-12b-v2-vl` is reached through its nginx sidecar (port 8080, see §6.1) and gets its URL at creation like the other apps; right after a deployment it answers `502` until the model has loaded.
> [!WARNING]
> Ingress is **external with no authentication** (as today): anyone with the URL can call your GPUs. Add IP restrictions (`ipSecurityRestrictions`) or use §8 before sharing the URLs.

---

## 8. Making everything private (optional)

The IaC ships with public ingress (`external: true`, environment `publicNetworkAccess: Enabled`).
There are two ways to remove public exposure of **all five apps at once** (ingress is an environment-level load balancer):

### Option A – Private endpoint on the existing environment (no environment re-creation)
Supported on workload-profiles environments (Microsoft Learn: *Use a private endpoint with an Azure Container Apps environment*; additional charges apply).

Bicep: set in `main.bicepparam`
```bicep
param publicNetworkAccess = 'Disabled'
param enablePrivateEndpoint = true
```
Terraform (`terraform.tfvars`):
```hcl
public_network_access   = "Disabled"
enable_private_endpoint = true
```

This creates a VNet/subnet, a private endpoint (`groupId: managedEnvironments`), the private DNS zone
`privatelink.<region>.azurecontainerapps.io`, a VNet link, and the A records `<env-unique-id>` and `*.<env-unique-id>` pointing to the endpoint IP.
For an existing environment, by CLI (`$envName` is the **name of the Azure Container Apps environment**, i.e. the `environmentName` parameter in Bicep, default `nim-gpu-env`, or `environment_name` in Terraform; it is not a shell environment variable. `$rg` is your resource group):
```powershell
$rg = '<resource-group>'
$envName = '<container-apps-environment-name>'   # list it with: az containerapp env list -g $rg --query "[].name" -o tsv
az containerapp env update -g $rg -n $envName --public-network-access Disabled
$envId = az containerapp env show -g $rg -n $envName --query id -o tsv
az network private-endpoint create -g $rg -n pe-$envName --vnet-name <vnet> --subnet <subnet> `
   --private-connection-resource-id $envId --group-id managedEnvironments --connection-name aca-env
# then: private DNS zone privatelink.<region>.azurecontainerapps.io, VNet link, A record(s) -> PE IP
```
Callers must be in the VNet (or peered / VPN / ExpressRoute) and use the private DNS zone. Per app you can then stop exposing at all by keeping `external: true` (reachable only through the PE now) – no per-app change needed.

### Option B – VNet-injected internal environment
Use when you also need control of **egress** (firewall/UDR) or want the Azure Files traffic on your VNet. The VNet is fixed at environment creation, so this means **re-creating the environment**.

```bicep
// in modules/environment.bicep -> properties
vnetConfiguration: {
  infrastructureSubnetId: subnetId   // /27 or larger, delegated to Microsoft.App/environments
  internal: true                     // internal load balancer, no public IP
}
```
Add a private DNS zone for the environment default domain with `*` → the environment's static (private) IP.
Serverless GPU replicas use **one IP per replica** in the subnet – size the subnet for your max replicas.

### Other pieces to privatize (both options)
| Component | Action |
|---|---|
| Azure Files (your new storage account) | Public with key access by default. To disable public access, add a private endpoint (`file` sub-resource, zone `privatelink.file.core.windows.net`) and a VNet-integrated environment (Option B) so the mount path stays on your network. Validate the mount on a test environment first. |
| ACR (owned by another team) | Out of scope for this guide. Whatever the other team does to it (private endpoint, authentication) must be coordinated with them; the two detection apps would then need registry credentials or an identity added. |
| `nvcr.io` / NGC | Cannot be private. In a locked-down VNet, allow outbound to `nvcr.io` and the NGC download endpoints (e.g. `authn.nvidia.com`, `api.ngc.nvidia.com`, `files.ngc.nvidia.com` – confirm against NVIDIA's current NIM networking docs), **or** pre-seed model weights on the share so less needs NGC at runtime (the NIM images themselves still come from `nvcr.io`). |
| Log Analytics | Optional: Azure Monitor Private Link Scope. |
