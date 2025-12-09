# rpiboot2swu

Tool for creating SWU backup of Unipi units in rpiboot mass storage mode.

Prerequisites:

- A device with USB port based on Linux
- USB Type-C cable
- Unipi unit

## Usage

1. Connect the device in rpiboot mass storage mode to your device.
2. Locate the correct block device of the unit (E.g. /dev/sda).
3. Run the script - `sh rpiboot2swu.sh DEVICE TARGET` (E.g. `sh rpiboot2swu.sh /dev/sda /home/unipi`).
If no target specified, current directory is used.
4. A restore tool is created in the target directory, which may be used to restore the swu to a block device.

### Restoring the swu to block device

It is possible to restore the swu back to a unit in rpiboot mass storage mode.
Keep in mind the restore script is specific to the swu and may not be swapped with another backup.
Restoring the backup on a wrong device may cause permanent data loss.

- Run in the target directory - `sh swu2rpiboot.sh DEVICE` (E.g. `sh swu2rpiboot.sh /dev/sda`).
