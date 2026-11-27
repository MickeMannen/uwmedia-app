// The watermark model and the layout that draws one
// (lib/core/watermark/watermark.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';

void main() {
  test('kept in the settings and read back; what is none is dropped', () {
    const logo = Watermark(
      name: 'Logo',
      picture: 'logo.png',
      anchor: 'TOP_LEFT',
      size: 0.2,
      opacity: 0.5,
    );
    final back = Watermark.fromJson(logo.toJson())!;
    expect(back.name, 'Logo');
    expect(back.picture, 'logo.png');
    expect(back.isPicture, isTrue);
    expect(
      (anchorOfPlace(back.place), back.size, back.opacity),
      ('TOP_LEFT', 0.2, 0.5),
    );
    expect(back.placePortrait, back.place);

    const name = Watermark(name: 'Name', text: '© Diver', color: '#FFCC00');
    final text = Watermark.fromJson(name.toJson())!;
    expect(
      (text.text, text.color, text.isPicture),
      ('© Diver', '#FFCC00', false),
    );
    // The defaults: a picture 15 % of the width, a text 3 %, bottom right.
    expect(
      (logo.copyWith().size, name.size, anchorOfPlace(name.place)),
      (0.2, 0.03, 'BOTTOM_RIGHT'),
    );
    expect(const Watermark(name: 'x', picture: 'p.png').size, 0.15);

    expect(Watermark.fromJson(null), isNull);
    expect(Watermark.fromJson({'name': 'x'}), isNull);
    // A picture is a file name in the app's folder, never a path.
    expect(Watermark.fromJson({'name': 'x', 'picture': '../x.png'}), isNull);
    expect(Watermark.fromJson({'name': ' ', 'text': 'hi'}), isNull);
    // Values out of range are brought in; an unknown place is the default.
    final odd = Watermark.fromJson({
      'name': 'odd',
      'text': 'hi',
      'anchor': 'SOMEWHERE',
      'size': 7,
      'color': 'red',
      'opacity': 0,
    })!;
    expect(
      (anchorOfPlace(odd.place), odd.size, odd.color),
      ('BOTTOM_RIGHT', 1.0, '#FFFFFF'),
    );
    expect(odd.opacity, watermarkMinOpacity);
  });

  test('a picture: its width a share of the frame, a margin inwards', () {
    final layout = watermarkLayout(
      const Watermark(name: 'Logo', picture: 'logo.png', opacity: 0.6),
      pictureSize: (600, 300),
    )!;
    final skin = layout['hud_skin'] as Map<String, dynamic>;
    expect(layout['design_width'], 1920);
    expect(skin['type'], 'image');
    // 15 % of 1920 design pixels from a picture 600 wide.
    expect(skin['scale'], closeTo(0.48, 1e-9));
    expect(skin['anchor'], 'BOTTOM_RIGHT');
    expect(skin['ref_offset_x'], closeTo(-9.6, 1e-9));
    expect(skin['ref_offset_y'], closeTo(-9.6, 1e-9));
    expect(skin['opacity'], 0.6);

    final top =
        watermarkLayout(
              const Watermark(
                name: 'Logo',
                picture: 'logo.png',
                anchor: 'TOP_CENTER',
              ),
              pictureSize: (600, 300),
            )!['hud_skin']
            as Map<String, dynamic>;
    expect(top['ref_offset_x'], 0.0);
    expect(top['ref_offset_y'], closeTo(9.6, 1e-9));

    expect(
      watermarkLayout(const Watermark(name: 'Logo', picture: 'logo.png')),
      isNull,
      reason: 'a picture that could not be measured draws nothing',
    );
  });

  test('a text: one element hung on the corner the anchor names', () {
    final skin =
        watermarkLayout(
              const Watermark(
                name: 'Name',
                text: '© Diver',
                anchor: 'TOP_LEFT',
              ),
            )!['hud_skin']
            as Map<String, dynamic>;
    expect(skin['type'], 'shape');
    expect(skin['opacity'], 0.0);
    final element = (skin['linked_elements'] as List).single as Map;
    expect(element['field'], 'custom:© Diver');
    expect((element['align'], element['valign']), ('left', 'top'));
    expect((element['rel_x'], element['rel_y']), (0.0, 0.0));
    expect(element['font_size'], closeTo(57.6, 1e-9));
    expect(element['outline'], isTrue);

    final right =
        ((watermarkLayout(const Watermark(name: 'Name', text: 'x'))!['hud_skin']
                        as Map)['linked_elements']
                    as List)
                .single
            as Map;
    expect((right['align'], right['valign']), ('right', 'bottom'));
    expect((right['rel_x'], right['rel_y']), (1.0, 1.0));
  });

  test('a place for landscape and one for portrait (spec §10.63)', () {
    // One kept with an anchor, as before the two places: both are it.
    final old = Watermark.fromJson({
      'name': 'Logo',
      'picture': 'logo.png',
      'anchor': 'TOP_RIGHT',
    })!;
    expect(old.place, (x: 1.0, y: 0.0));
    expect(old.placePortrait, (x: 1.0, y: 0.0));
    expect(old.toJson()['place'], [1.0, 0.0]);
    expect(old.toJson().containsKey('anchor'), isFalse);

    final mark = old.copyWith(placePortrait: (x: 0.5, y: 1.0));
    expect(mark.place, (x: 1.0, y: 0.0));
    expect(mark.placeOn(1920, 1080), mark.place);
    expect(mark.placeOn(1080, 1080), mark.place, reason: 'a square frame');
    expect(mark.placeOn(1080, 1920), (x: 0.5, y: 1.0));
    final back = Watermark.fromJson(mark.toJson())!;
    expect((back.place, back.placePortrait), (mark.place, mark.placePortrait));

    Map<String, dynamic> skinOn(int w, int h) =>
        watermarkLayout(
              mark,
              pictureSize: (600, 300),
              frameW: w,
              frameH: h,
            )!['hud_skin']
            as Map<String, dynamic>;
    expect(skinOn(3840, 2160)['anchor'], 'TOP_RIGHT');
    expect(skinOn(1080, 1920)['anchor'], 'BOTTOM_CENTER');
    expect(skinOn(1080, 1920)['ref_offset_x'], 0.0);
    expect(skinOn(1080, 1920)['ref_offset_y'], closeTo(-9.6, 1e-9));

    // Values out of the frame are brought in; what is no pair is none.
    final odd = Watermark.fromJson({
      'name': 'x',
      'text': 'hi',
      'place': [1.7, -2],
      'place_portrait': 'up',
    })!;
    expect(odd.place, (x: 1.0, y: 0.0));
    expect(odd.placePortrait, odd.place);
  });

  test('the nine places and the lines a dragged mark is taken onto', () {
    for (final anchor in watermarkAnchors) {
      expect(anchorOfPlace(placeOfAnchor(anchor)), anchor);
    }
    expect(anchorOfPlace((x: 0.3, y: 1)), isNull);
    expect(watermarkPlaceText((x: 0.5, y: 0)), 'Top');
    expect(watermarkPlaceText((x: 0.3, y: 0.2)), 'Placed by hand');

    expect(snappedPlace((x: 0.04, y: 0.97)), (x: 0.0, y: 1.0));
    expect(snappedPlace((x: 0.46, y: 0.3)), (x: 0.5, y: 0.3));
    expect(snappedPlace((x: 0.2, y: 0.56)), (x: 0.2, y: 0.56));
    expect(snappedPlace((x: -3, y: 9)), (x: 0.0, y: 1.0));
    expect(snappedPlace((x: double.nan, y: 0.3)).x, 0.5);
  });

  test('a picture between the nine: by its own size, inside the margins', () {
    const mark = Watermark(
      name: 'Logo',
      picture: 'logo.png',
      size: 0.25,
      place: (x: 0.25, y: 0.75),
      placePortrait: (x: 1, y: 0.4),
    );
    // On 1920 x 1080 design pixels: 480 x 240 with a margin of 9.6.
    final skin =
        watermarkLayout(mark, pictureSize: (600, 300))!['hud_skin']
            as Map<String, dynamic>;
    expect(skin['anchor'], 'TOP_LEFT');
    expect(skin['scale'], closeTo(0.8, 1e-9));
    expect(
      skin['ref_offset_x'],
      closeTo(9.6 + 0.25 * (1920 - 19.2 - 480), 1e-9),
    );
    expect(
      skin['ref_offset_y'],
      closeTo(9.6 + 0.75 * (1080 - 19.2 - 240), 1e-9),
    );

    // A portrait frame: its own place, on a frame 1920 x 3413.3 design
    // pixels; against the right margin whatever the frame's width.
    final upright =
        watermarkLayout(
              mark,
              pictureSize: (600, 300),
              frameW: 1080,
              frameH: 1920,
            )!['hud_skin']
            as Map<String, dynamic>;
    expect(upright['ref_offset_x'], closeTo(1920 - 9.6 - 480, 1e-9));
    expect(
      upright['ref_offset_y'],
      closeTo(9.6 + 0.4 * (1920 * 1920 / 1080 - 19.2 - 240), 1e-9),
    );
    // The same share of the way on a frame of another shape.
    final wide =
        watermarkLayout(
              mark,
              pictureSize: (600, 300),
              frameW: 2000,
              frameH: 1000,
            )!['hud_skin']
            as Map<String, dynamic>;
    expect(
      wide['ref_offset_y'],
      closeTo(9.6 + 0.75 * (960 - 19.2 - 240), 1e-9),
    );
  });

  test('a text between the nine: by its measured box, else the nearest', () {
    const free = (x: 0.3, y: 0.6);
    const text = Watermark(name: 'Name', text: '© Diver', place: free);
    // Not measured: the nearest of the nine, hung as a text always was.
    final near = watermarkLayout(text)!['hud_skin'] as Map<String, dynamic>;
    expect(near['anchor'], 'MIDDLE_CENTER');
    expect(near['width'], 8.0);
    expect(
      ((near['linked_elements'] as List).single as Map)['align'],
      'center',
    );

    // Measured, 4 letter heights wide and 0.75 high: a box of 230.4 x
    // 43.2 design pixels with the text in its middle.
    final measured = text.copyWith(textBox: (4.0, 0.75));
    final skin = watermarkLayout(measured)!['hud_skin'] as Map<String, dynamic>;
    expect(skin['anchor'], 'TOP_LEFT');
    expect(skin['opacity'], 0.0);
    expect(skin['width'], closeTo(230.4, 1e-9));
    expect(skin['height'], closeTo(43.2, 1e-9));
    expect(
      skin['ref_offset_x'],
      closeTo(9.6 + 0.3 * (1920 - 19.2 - 230.4), 1e-9),
    );
    expect(
      skin['ref_offset_y'],
      closeTo(9.6 + 0.6 * (1080 - 19.2 - 43.2), 1e-9),
    );
    final element = (skin['linked_elements'] as List).single as Map;
    expect((element['align'], element['valign']), ('center', 'middle'));
    expect((element['rel_x'], element['rel_y']), (0.5, 0.5));
    // At one of the nine it lies by its box too, so that it does not
    // shift when it is dragged off it.
    final corner =
        watermarkLayout(measured.copyWith(place: (x: 1, y: 1)))!['hud_skin']
            as Map<String, dynamic>;
    expect(corner['anchor'], 'TOP_LEFT');
    expect(corner['ref_offset_x'], closeTo(1920 - 9.6 - 230.4, 1e-9));

    // Kept and read back; other words are not measured yet.
    final back = Watermark.fromJson(measured.toJson())!;
    expect(back.textBox, (4.0, 0.75));
    expect(measured.copyWith(text: 'Other').textBox, isNull);
    expect(measured.copyWith(text: '© Diver', size: 0.05).textBox, (4.0, 0.75));
  });

  test('a mark for one kind of frame draws nothing on the other', () {
    const mark = Watermark(
      name: 'Logo',
      picture: 'logo.png',
      frames: watermarkFramesPortrait,
    );
    expect(mark.usedOn(1920, 1080), isFalse);
    expect(mark.usedOn(1080, 1080), isFalse);
    expect(mark.usedOn(1080, 1920), isTrue);
    final wide = watermarkLayout(mark, pictureSize: (200, 100))!;
    final skin = wide['hud_skin'] as Map<String, dynamic>;
    expect(skin['type'], 'shape');
    expect(skin['opacity'], 0.0);
    expect(skin['linked_elements'], isEmpty);
    final upright = watermarkLayout(
      mark,
      pictureSize: (200, 100),
      frameW: 1080,
      frameH: 1920,
    )!;
    expect((upright['hud_skin'] as Map<String, dynamic>)['type'], 'image');
    // Kept, and read back; one kept before is for both.
    expect(Watermark.fromJson(mark.toJson())!.frames, watermarkFramesPortrait);
    expect(
      Watermark.fromJson({'name': 'a', 'text': 'b'})!.frames,
      watermarkFramesBoth,
    );
    expect(
      const Watermark(name: 'a', text: 'b').toJson(),
      isNot(contains('frames')),
    );
  });

  test('a size of its own on portrait frames (spec §10.105)', () {
    // Until it has one, the portrait size is the landscape one.
    const one = Watermark(name: 'Logo', picture: 'logo.png', size: 0.2);
    expect(one.sizePortrait, 0.2);
    expect(one.toJson().containsKey('size_portrait'), isFalse);
    expect(identical(one.shaped(portrait: true), one), isTrue);
    expect(one.copyWith(size: 0.3).sizePortrait, 0.3, reason: 'it follows');

    final two = one.copyWith(sizePortrait: 0.4);
    expect(two.size, 0.2);
    expect(two.sizeOn(1920, 1080), 0.2);
    expect(two.sizeOn(1080, 1080), 0.2, reason: 'a square is landscape');
    expect(two.sizeOn(1080, 1920), 0.4);
    expect(two.copyWith(size: 0.3).sizePortrait, 0.4, reason: 'its own now');
    expect(two.shaped(portrait: true).size, 0.4);
    expect(identical(two.shaped(portrait: false), two), isTrue);

    // Kept and read back; out of range is brought in; an old entry has
    // the one size for both.
    final json = two.toJson();
    expect(json['size_portrait'], 0.4);
    final back = Watermark.fromJson(json)!;
    expect((back.size, back.sizePortrait), (0.2, 0.4));
    expect(
      Watermark.fromJson({...json, 'size_portrait': 9})!.sizePortrait,
      watermarkMaxSize,
    );
    expect(
      Watermark.fromJson({...json}..remove('size_portrait'))!.sizePortrait,
      0.2,
    );

    // Drawn: a picture 600 wide is 0.2 x 1920 / 600 on a landscape frame
    // and 0.4 x 1920 / 600 on a portrait one, each at its own place.
    Map<String, dynamic> skin(int w, int h) =>
        watermarkLayout(
              two,
              pictureSize: (600, 300),
              frameW: w,
              frameH: h,
            )!['hud_skin']
            as Map<String, dynamic>;
    expect(skin(1920, 1080)['scale'], closeTo(0.64, 1e-9));
    expect(skin(1080, 1920)['scale'], closeTo(1.28, 1e-9));
    expect(
      watermarkShare(two.shaped(portrait: true), pictureSize: (600, 300)),
      (0.4, 0.2),
    );

    // A text: its letters.
    final text = const Watermark(
      name: 'Name',
      text: '© Diver',
      size: 0.03,
    ).copyWith(sizePortrait: 0.06);
    double letters(int w, int h) =>
        (((watermarkLayout(text, frameW: w, frameH: h)!['hud_skin']
                            as Map<String, dynamic>)['linked_elements']
                        as List<dynamic>)
                    .single
                as Map<String, dynamic>)['font_size']
            as double;
    expect(letters(1920, 1080), closeTo(0.03 * 1920, 1e-9));
    expect(letters(1080, 1920), closeTo(0.06 * 1920, 1e-9));
  });
}
