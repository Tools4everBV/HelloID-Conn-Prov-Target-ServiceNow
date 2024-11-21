# HelloID-Conn-Prov-Target-ServiceNow

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://www.servicenow.com/content/dam/servicenow-assets/images/naas/servicenow-header-logo.svg">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-ServiceNow](#helloid-conn-prov-target-servicenow)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Getting started](#getting-started)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Available lifecycle actions](#available-lifecycle-actions)
    - [Field mapping](#field-mapping)
  - [Remarks](#remarks)
    - [Account validation based on `email`](#account-validation-based-on-email)
    - [UTF8 encoding](#utf8-encoding)
    - [Department, Location, and Manager Fields](#department-location-and-manager-fields)
  - [Development resources](#development-resources)
    - [API documentation](#api-documentation)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-ServiceNow_ is a _target_ connector. ServiceNow is a cloud-based platform that provides various software-as-a-service (SaaS) solutions for enterprise-level service management and IT operations management. It is primarily known for its IT Service Management (ITSM) capabilities, but it offers a wide range of applications and services for various departments within an organization.

## Getting started

### Connection settings

The following settings are required to connect to the API.

| Setting  | Description                                   | Mandatory | Example                               |
| -------- | --------------------------------------------- | --------- | ------------------------------------- |
| UserName | The UserName to connect to the ServiceNow API | Yes       | -                                     |
| Password | The Password to connect to the ServiceNow API | Yes       | -                                     |
| BaseUrl  | The URL to the ServiceNow environment         | Yes       | https://{environment}.service-now.com |

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _ServiceNow_ to a person in _HelloID_.

| Setting                   | Value                             |
| ------------------------- | --------------------------------- |
| Enable correlation        | `True`                            |
| Person correlation field  | `Accounts.MicrosoftActiveDirectory.UserPrincipalName` |
| Account correlation field | `email`                  |

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Available lifecycle actions

The following lifecycle actions are available:

| Action             | Description                                                                     |
| ------------------ | ------------------------------------------------------------------------------- |
| create.ps1         | Creates a new account.                                                          |
| disable.ps1        | Disables an account, preventing access without permanent removal.               |
| enable.ps1         | Enables an account, granting access.                                            |
| update.ps1         | Updates the attributes of an account.                                           |
| configuration.json | Contains the connection settings and general configuration for the connector.   |
| fieldMapping.json  | Defines mappings between person fields and target system person account fields. |

### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

## Remarks

### Account validation based on `email`

Due to an empty employee_number in a test environment, the account validation for version `1.0.0` of this connector relies on the email address instead.<br><br>You can modify it to use a different property, such as employee_number or any other field that suits your requirements.

### UTF8 encoding

By default, version `1.0.0` handles UTF-8 encoding. This ensures that data is appropriately encoded. Encoding is handled in both the `create` and `update` lifecycle actions.

### Department, Location, and Manager Fields

The `department`, `location`, and `manager` fields are linked objects. This means we must ensure they exist in _ServiceNow_ and use the correct `sys_id` for updates.

- **Create**:
  When creating a user, we ensure that the `manager`, `department`, and `location` exist in _ServiceNow_. If any of these fields do not exist:
  1. A warning is logged.
  2. The property is removed from the JSON payload before submission.
  3.
- **Update**:
  When updating a user’s department, location, or manager in _ServiceNow_, we:
  1. Verify if the corresponding values in `$correlatedAccount` exist and match a unique identifier pattern via a regular expression.
  2. Retrieve the related record from _ServiceNow_ if the conditions are met.
  3. Compare the `name` field of the retrieved record to the value in `$actionContext.Data`.
  4. If there’s a discrepancy, update the `$actions` array with one of the following:
     - `UpdateLocation`
     - `UpdateDepartment`
     - `UpdateManager`

## Development resources

### API documentation

API documentation can be found on: https://docs.servicenow.com/bundle/utah-api-reference/page/integrate/inbound-rest/concept/c_TableAPI.html

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
>  _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/4864-helloid-conn-prov-target-servicenow)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
