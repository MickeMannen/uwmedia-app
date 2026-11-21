/// The dive computers the Dive Profile Builder can pose as when it writes
/// a log (Python `utils/dive_computers.py`): one per bundled overlay
/// template computer, so that an invented log can drive that computer's
/// own templates. Each format names the device the way the computer's real
/// exports do.
library;

class DiveComputer {
  const DiveComputer(
    this.label,
    this.manufacturer,
    this.model, {
    this.fitProduct,
  });

  /// "Shearwater Perdix 2": the name in the UI and a plan's `computer`.
  final String label;

  /// As in the template manifest.
  final String manufacturer;

  /// The UDDF computer name, "Perdix 2" or "Descent Mk3i".
  final String model;

  /// The FIT `garmin_product` id; `null` for a computer that writes no FIT.
  final int? fitProduct;

  bool get isGarmin => fitProduct != null;
}

/// The computers by label, in the order the UI lists them. 4518 is not in
/// the FIT SDK's product table yet; the Garmin parser maps it by hand.
const Map<String, DiveComputer> diveComputers = {
  'Garmin Descent Mk3i': DiveComputer(
    'Garmin Descent Mk3i',
    'Garmin',
    'Descent Mk3i',
    fitProduct: 4223,
  ),
  'Garmin Descent X50i': DiveComputer(
    'Garmin Descent X50i',
    'Garmin',
    'Descent X50i',
    fitProduct: 4518,
  ),
  'Shearwater Perdix 2': DiveComputer(
    'Shearwater Perdix 2',
    'Shearwater',
    'Perdix 2',
  ),
  'Shearwater Perdix 3': DiveComputer(
    'Shearwater Perdix 3',
    'Shearwater',
    'Perdix 3',
  ),
  'Shearwater Petrel 3': DiveComputer(
    'Shearwater Petrel 3',
    'Shearwater',
    'Petrel 3',
  ),
  'Shearwater Peregrine TX': DiveComputer(
    'Shearwater Peregrine TX',
    'Shearwater',
    'Peregrine TX',
  ),
  'Shearwater Teric': DiveComputer('Shearwater Teric', 'Shearwater', 'Teric'),
  'Shearwater Tern': DiveComputer('Shearwater Tern', 'Shearwater', 'Tern'),
  'Suunto EON Core': DiveComputer('Suunto EON Core', 'Suunto', 'EON Core'),
  'Suunto EON Steel Black': DiveComputer(
    'Suunto EON Steel Black',
    'Suunto',
    'EON Steel Black',
  ),
  'Suunto Nautic': DiveComputer('Suunto Nautic', 'Suunto', 'Nautic'),
};

const defaultDiveComputer = 'Shearwater Perdix 2';

/// Labels older versions saved in plans and settings, and the computer
/// each is now.
const legacyComputerLabels = {
  'Shearwater Petrel': 'Shearwater Petrel 3',
  'Shearwater Peregrine': 'Shearwater Peregrine TX',
};

/// A saved label as it is named today.
String computerLabel(String label) => legacyComputerLabels[label] ?? label;

/// The computer of a plan's label; an unknown label gives the default
/// rather than failing a save.
DiveComputer diveComputer(String label) =>
    diveComputers[computerLabel(label)] ?? diveComputers[defaultDiveComputer]!;
