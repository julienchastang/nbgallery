# Integrating Jupyter with nbgallery

## Overview

One of the benefits of nbgallery is its two-way integration with Jupyter.  You can launch notebooks from nbgallery into Jupyter with a single click.  Within Jupyter, the Gallery menu enables you to save notebooks to nbgallery and submit change requests to other notebook authors.

`Run in Jupyter` now launches through an external `nblaunch` service using short-lived signed URLs generated server-side by nbgallery.

Required server configuration:

* `NBLAUNCH_SHARED_SECRET` (required): shared HMAC secret used to sign launch requests.
* `NBLAUNCH_BASE_URL` (required): base launcher URL for your deployment, for example:
  * `https://<your-jupyterhub>/services/nblaunch/launch`

The launch URL format is:

```
<NBLAUNCH_BASE_URL>?nb=<NOTEBOOK_ID>&ts=<UNIX_EPOCH_SECONDS>&sig=<HMAC_SHA256_HEX>
```

Where:

* `nb` is the notebook identifier only (no `.nb` or `.ipynb` suffix).
* `ts` is the current unix timestamp in seconds.
* `sig` is `HMAC_SHA256(NBLAUNCH_SHARED_SECRET, "#{nb}:#{ts}")` as lowercase hex.

These links are generated just-in-time when the button is clicked, so they remain valid within the launcher TTL window.

You can launch a full suite of nbgallery/mysql/solr plus an integrated Jupyter instance using our docker compose files:

```
docker-compose -f docker-compose.yml -f docker-compose-with-jupyter.yml up
```

## Technical details

For notebook launch, nbgallery now performs a server-side redirect to a signed `nblaunch` URL.  The signing secret is never exposed to the browser.

The legacy cross-domain Ajax upload flow is still relevant for older integrations and optional extensions, but it is no longer the primary `Run in Jupyter` launch path.

## Optional integration scripts

Our [jupyter_nbgallery extension](https://github.com/nbgallery/nbgallery-extensions) can optionally download additional integration javascripts from nbgallery.  This can be configured in the `nbgallery` section of Jupyter's `nbconfig/common.json` ([here's a stub](https://github.com/nbgallery/jupyter-alpine/blob/master/config/jupyter/nbconfig/common.json)).  There are two optional javascripts in the nbgallery codebase:

 * [**Notebook instrumentation**](../public/integration/gallery-instrumentation.js): This enables logging of cell executions back to nbgallery.  This is required for our [notebook health evaluation](https://nbgallery.github.io/health_paper.html), which feeds into our [notebook recommender](https://nbgallery.github.io/recommendation.html) when enabled.  To enable instrumentation:
   * If using our docker image: Set `-e NBGALLERY_ENABLE_INSTRUMENTATION=1` on the `docker run` command line
   * Manual configuration: Add `"gallery-instrumentation.js"` to the `nbgallery.extra_integration.notebook` list in `nbconfig/common.json`.  
 
 * [**Automatic downloads at startup**](../public/integration/gallery-autodownload.js): This will automatically download your recently executed and starred notebooks into folders when you first visit the Jupyter `/tree` page.  This is useful to restore your favorite notebooks if your Jupyter environment is not persistent.  Note that instrumentation must also be enabled to auto-download recently executed notebooks.  To enable auto-download:
   * If using our docker image: Set `-e NBGALLERY_ENABLE_AUTODOWNLOAD=1` on the `docker run` command line
   * Manual configuration: Add `"gallery-autodownload.js"` to the `nbgallery.extra_integration.tree` list in `nbconfig/common.json` to 

You can add custom javascripts to your nbgallery instance through our extension system.

## Manual configuration

If you're not using our docker image for Jupyter, you can still configure Jupyter to integrate with nbgallery:

 * Install our [jupyter_nbgallery extension](https://github.com/nbgallery/nbgallery-extensions).  This contains a server extension for uploading notebooks and a UI extension to add the Gallery menu.
 * Set the following [configuration settings](https://jupyter-notebook.readthedocs.io/en/stable/config.html) in `jupyter_notebook_config.py` ([here's ours](https://github.com/nbgallery/jupyter-alpine/blob/master/config/jupyter/jupyter_notebook_config.py)) or on the command line (for legacy browser-based integrations):
   * `JupyterApp.allow_origin = <URL of your nbgallery instance>`
   * `JupyterApp.allow_credentials = True`
   * `JupyterApp.disable_check_xsrf = True` (note this reduces the security of Jupyter but is necessary for the `Run in Jupyter` button to work)
 * Add an nbgallery section to Jupyter's `nbconfig/common.json`, usually found in `~/.jupyter/nbconfig` ([here's ours](https://github.com/nbgallery/jupyter-alpine/blob/master/config/jupyter/nbconfig/common.json)).  At a minimum, you need to set the URL of your nbgallery instance.  You can also set the client name here; that will show up as the environment name in nbgallery.  Any desired integration scripts (described above) should be enabled here as well.

For `nblaunch`-based launch, configure the `NBLAUNCH_*` settings on the nbgallery server and deploy a compatible launcher service endpoint.

We believe this is possible with JupyterHub as well, but we haven't tried it ourselves.  If you've tried it, please [let us know how it went](https://github.com/nbgallery/nbgallery/issues/new).
