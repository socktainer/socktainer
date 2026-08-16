/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** glassdockctl Executable - Optional absolute path to glassdockctl. Standard install locations are detected automatically. */
  "controlExecutable"?: string
}
/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `glass-dock` command */
  export type GlassDock = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `glass-dock` command */
  export type GlassDock = {}
}
