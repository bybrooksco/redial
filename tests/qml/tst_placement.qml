import QtQuick
import QtTest
import "../../plugin/redial/Placement.js" as Place

TestCase {
  name: "Placement"

  // screen 1000 x 600, overlay 200 x 100, margin 20
  function test_bottom_is_centred_on_the_bottom_edge() {
    compare(Place.x("bottom", -1, -1, 200, 1000, 20), 400)
    compare(Place.y("bottom", -1, -1, 100, 600, 20), 480)
  }

  function test_bottom_margin_only_changes_the_bottom_edge() {
    compare(Place.y("bottom", -1, -1, 100, 600, 20, 67), 433)
    compare(Place.y("top", -1, -1, 100, 600, 20, 67), 20)
  }

  function test_corners() {
    compare(Place.x("top-left", -1, -1, 200, 1000, 20), 20)
    compare(Place.y("top-left", -1, -1, 100, 600, 20), 20)
    compare(Place.x("bottom-right", -1, -1, 200, 1000, 20), 780)
    compare(Place.y("bottom-right", -1, -1, 100, 600, 20), 480)
  }

  function test_centre_and_sides() {
    compare(Place.x("center", -1, -1, 200, 1000, 20), 400)
    compare(Place.y("center", -1, -1, 100, 600, 20), 250)
    compare(Place.x("left", -1, -1, 200, 1000, 20), 20)
    compare(Place.y("left", -1, -1, 100, 600, 20), 250)
    compare(Place.x("right", -1, -1, 200, 1000, 20), 780)
  }

  function test_a_free_point_wins_and_is_clamped() {
    compare(Place.x("bottom", 500, 300, 200, 1000, 20), 400)
    compare(Place.y("bottom", 500, 300, 100, 600, 20), 250)
    compare(Place.x("bottom", 5, 300, 200, 1000, 20), 20)
    compare(Place.y("bottom", 500, 599, 100, 600, 20), 480)
  }

  function test_half_free_is_not_free() {
    compare(Place.x("bottom", 500, -1, 200, 1000, 20), 400)
    compare(Place.y("bottom", 500, -1, 100, 600, 20), 480)
  }

  function test_unknown_anchor_falls_back_to_centre() {
    compare(Place.x("sideways", -1, -1, 200, 1000, 20), 400)
    compare(Place.y(undefined, -1, -1, 100, 600, 20), 250)
  }

  function test_origin_matches_the_edge() {
    compare(Place.origin("bottom", -1, -1), Item.Bottom)
    compare(Place.origin("top-left", -1, -1), Item.TopLeft)
    compare(Place.origin("bottom-right", -1, -1), Item.BottomRight)
    compare(Place.origin("right", -1, -1), Item.Right)
    compare(Place.origin("center", -1, -1), Item.Center)
    compare(Place.origin("bottom", 10, 10), Item.Center)
  }
}
