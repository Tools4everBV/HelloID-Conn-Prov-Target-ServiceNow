
# HelloID-Conn-Prov-Target-ServiceNow

| :information_source: Information |
|:---------------------------|
| This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements. |

<p align="center">
  <img src="https://www.tools4ever.nl/connector-logos/servicenow-logo.png">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-ServiceNow](#helloid-conn-prov-target-servicenow)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Getting started](#getting-started)
    - [Connection settings](#connection-settings)
    - [Remarks](#remarks)
      - [Account object properties](#account-object-properties)
      - [Account validation based on `email`](#account-validation-based-on-email)
      - [Update using a `PUT`](#update-using-a-put)
        - [Full `PUT` in the `create` lifecycle action](#full-put-in-the-create-lifecycle-action)
        - [Partial `PUT` in the `update` lifecycle action](#partial-put-in-the-update-lifecycle-action)
      - [UTF8 encoding](#utf8-encoding)
      - [Creation / correlation process](#creation--correlation-process)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-ServiceNow_ is a _target_ connector. ServiceNow is a cloud-based platform that provides various software-as-a-service (SaaS) solutions for enterprise-level service management and IT operations management. It is primarily known for its IT Service Management (ITSM) capabilities, but it offers a wide range of applications and services for various departments within an organization.

| Endpoint     | Description |
| ------------ | ----------- |
| table/sys_user | In ServiceNow, the _sys_user_ table is one of the core tables that stores information about users in the system. It is a fundamental table used for managing user records and is heavily used in various processes and modules within ServiceNow.

>:information_source:__API documentation<br> https://docs.servicenow.com/bundle/utah-api-reference/page/integrate/inbound-rest/concept/c_TableAPI.html

The following lifecycle events are available:

| Event  | Description | Notes |
|---	 |---	|---	|
| create.ps1 | Create (or update) and correlate an Account | - |
| update.ps1 | Update the Account | - |
| enable.ps1 | Enable the Account | - |
| disable.ps1 | Disable the Account | - |

## Getting started

### Connection settings

The following settings are required to connect to the API.

| Setting| Description| Mandatory   | Example
| ------------ | -----------| ----------- | ----------|
| UserName| The UserName to connect to the ServiceNow API | Yes| -
| Password| The Password to connect to the ServiceNow API | Yes| -
| BaseUrl| The URL to the ServiceNow environment | Yes| https://{environment}.service-now.com

### Remarks

#### Account object properties

Currently, version `1.0.0` of the connector supports the following user properties:

| Property        | Description                                                         |
|-----------------|---------------------------------------------------------------------|
| user_name       | Represents the user's username or login ID.                         |
| employee_number | Stores the employee number associated with the user.                |
| email           | Holds the user's email address from the business contact details.   |
| name            | The user's full display name.                                       |
| first_name      | The user's given (first) name.                                      |
| middle_name     | The user's middle name.                                             |
| last_name       | The user's family (last) name.                                      |
| gender          | The gender of the user, converted from a code to a human-readable form.  |
| home_phone      | The user's fixed (landline) phone number from personal contact details.  |
| street          | The street address of the user's personal address.                  |
| zip_code        | The postal code or ZIP code of the user's personal address.         |
| city            | The city of the user's personal address.                            |
| country         | The country of the user's personal address.                         |
| phone           | The user's fixed (landline) phone number from business contact details. |
| mobile_phone    | The user's mobile phone number from business contact details.       |
| title           | The job title of the user, retrieved from the primary contract.     |
| manager         | The primary manager of the user, retrieved from the primary manager object. |
| active          | A boolean indicating whether the user account is active or inactive. |
| locked_out      | A boolean indicating whether the user account is locked out. |

Example:

```powershell
$account = [PSCustomObject]@{
    user_name       = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName
    employee_number = $p.ExternalId
    email           = $p.Accounts.MicrosoftActiveDirectory.userPrincipalName
    first_name      = $p.Name.Nickname
    last_name       = $p.Accounts.MicrosoftActiveDirectory.sn
    gender          = switch ($p.Details.Gender) {
        'F' { 'Female' }
        'M' { 'Male' }
        'X' { 'Undefined' }
    }
    home_phone      = $p.contact.Personal.phone.Fixed
    street          = $p.contact.Personal.Address.Street
    zip_code        = $p.contact.Personal.Address.PostalCode
    city            = $p.contact.Personal.Address.Locality
    country         = $p.contact.Personal.Address.Country
    phone           = $p.Contact.Business.Phone.Fixed
    mobile_phone    = $p.Contact.Business.Phone.Mobile
    department      = $p.PrimaryContract.Department.DisplayName
    manager         = "" # manager is determined automatically later in script
    title           = $p.PrimaryContract.Title.Name
    location        = $p.PrimaryContract.Department.DisplayName
    active          = $false
    locked_out      = $true
}
```

#### Account validation based on `email`

>:exclamation:Due to an empty employee_number in a test environment, the account validation for version `1.0.0` of this connector relies on the email address instead.<br><br>You can modify it to use a different property, such as employee_number or any other field that suits your requirements.

To customize the validation property:

1. Open the __create lifecycle__ action in your code editor or directly from HelloID.
2. Nagivate to line __14__.
3. Modify the variables: _'$correlationProperty and $correlationValue'_ according to your requirements.

>:information_source:Search query `sysparm_query` is not a typo!

Additinally, we have to correlate to the servicenow user of the manager, since we need to use the id in the account mapping.
To customize the manager validation property:

1. Open the __create lifecycle__ action in your code editor or directly from HelloID.
2. Navigate to line __17__.
3. Modify the variables: _'$managerCorrelationProperty and $managercorrelationValue'_ according to your requirements.
4. Open the __update lifecycle__ action in your code editor or directly from HelloID.
5. Navigate to line __15__.
6. Modify the variables: _'$managerCorrelationProperty and $managercorrelationValue'_ according to your requirements.

#### Update using a `PUT`

##### Full `PUT` in the `create` lifecycle action

The update process in the `create` lifecycle action is used to update the account with ServiceNow. However, it selectively replaces the properties: `active` and `locked_out`, with values retrieved from ServiceNow to ensure their status remains consistent and not overridden.

##### Partial `PUT` in the `update` lifecycle action

In the `update` lifecycle action, a partial PUT method is used to modify only specific properties of a user object in the ServiceNow, without having to send the entire object.

#### UTF8 encoding

By default, version `1.0.0` handles UTF-8 encoding. This ensures that data is appropriately encoded. Encoding is handled in both the `create` and `update` lifecycle actions using the code block listed below.

```powershell
$body = $account | ConvertTo-Json
$splatInvokeRestMethodProps['Body'] = [System.Text.Encoding]::UTF8.GetBytes($body)
```

#### Creation / correlation process

A new functionality is the possibility to update the account in the target system during the correlation process. By default, this behavior is disabled. Meaning, the account will only be created or correlated.

You can change this behavior in the `configuration` by setting the checkbox `UpdatePersonOnCorrelate` to the value of `true`.

> Be aware that this might have unexpected implications.

## Getting help

> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/hc/en-us/articles/360012558020-Configure-a-custom-PowerShell-target-system) pages_

> _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com)_

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
