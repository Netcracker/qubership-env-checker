# Authorization Methods for Env-Checker Service

This document describes the various authentication methods supported by the Env-Checker service, including configuration
details and default behaviors.

## Overview

The Env-Checker service supports multiple ways to handle user authorization. The method used depends on the environment
configuration and specific parameters set during deployment.

### 1. Integration with Identity Provider (IDP)

If the environment is configured to use an external Identity Provider (IDP), such as Keycloak, the integration is
considered enabled when the _OPS_IDP_URL_ parameter is set.

When OPS_IDP_URL exists and points to a valid IDP URL, the service assumes that external authentication is configured.
In addition to the filled in parameter OPS_IDP_URL, the following parameters must also be filled in for integration with
IDP:

| **Parameter**                      | **Value Example**                | **Description**                                                                                                                                                |
| ---------------------------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OPS_IDP_URL                        | `https://keycloak.k8s.org`       | URL to keycloak. If IDP parameters are not defined then access to Env Checker is allowable via Jupiter default token                                           |
| ENVCHECKER_KEYCLOACK_REALM         | test-realm                       | Name of IDP realm. User for Env-checker authentication have to belong to the realm                                                                             |
| ENVCHECKER_KEYCLOACK_CLIENT_ID     | test-env-checker-client          | IDP Client ID which have to belong to the realm. Client parameter in IDP 'Valid Redirect URIs' have to contain env-checker ingress URL                         |
| ENVCHECKER_KEYCLOACK_CLIENT_SECRET | b4iwkh7nQBSxIgBEtlYSxUfNuoGZY19K | IDP Client Secret. The value can be viewed in the Credentials tab on the idp client.\_If there is no Credentials tab. Set the Client authentication flag to ON |

In case of using IDP integration, the standard Jupyter UI authorization page will not be displayed. Authorization will
be considered successful immediately after passing in Keycloak authorization If integration with IDP is not configured,
you need to choose one of the following two approaches: _Local Token Authentication_ or _Default Mode_.

### 2. Local Token Authentication

If the OPS_IDP_URL parameter is not set, the service falls back to token-based authentication, which can be configured
via optional environment parameter ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN. If set, this token is used for authentication.
It can be any string value, typically a secure token.

If ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN is not set or is empty, the _Default Mode_ will be selected.

### 3. Default Mode

By default, if no parameters are provided, the service automatically generates a random token of 32 characters.
This mode ensures that the UI is protected with a token, but it is dynamically created at startup, providing a basic
level of security.

## How to view token

The token can be viewed in Kubernetes secret named env-checker-ui-access-token or the logs of the Env-Checker pod
during startup.
Also can view the token run the next command:

```bash
kubectl get secret env-checker-ui-access-token -o jsonpath="{.data.access-token}" | base64 --decode
```

## Additional Notes

* When using external IDP, the internal login UI is **disabled** and users authenticate via the external provider.
* When using local token authentication, the token value is always available in the Kubernetes secret
`env-checker-ui-access-token`.
* The randomly generated token can be used for quick setup or testing but should be replaced with a secure, known token
in production.
