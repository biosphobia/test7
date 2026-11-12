class_name PointElement
extends Resource
## What a cloud's atoms are made of: how they behave once knocked loose.
## Assign one to PointCloud.element. Like elements in real life, each kind has
## its own weight, bounciness and so on; the look of an atom stays the same.
##
## The physics runs entirely in the vertex shader as a closed-form path per
## atom (launch, fall, bounces, slide to rest), so a million loose atoms cost
## the same as a million resting ones and nothing is simulated on the CPU.
## Atoms collide with the ground plane (PointCloud.floor_y); they don't collide
## with each other or with other objects.

@export var name := "Ember"
## Downward acceleration of loose atoms, m/s².
@export var gravity := 3.0
## Seconds until loose atoms fade away. 0 = they stay for good.
@export var lifetime := 2.0
## Loose atoms land on the ground instead of falling through it.
@export var lands := false
## How much speed an atom keeps when it bounces (0 = thud, 0.9 = rubber).
@export_range(0.0, 0.95) var bounce := 0.3
## How much sideways speed an atom loses on each bounce.
@export_range(0.0, 1.0) var friction := 0.4
## Air resistance (1/s): light atoms slow down and drift.
@export var drag := 0.0
## How brightly atoms glow as they break off.
@export var glow := 1.0
## Resistance to being chipped: hits make craters this many times smaller.
@export var hardness := 1.0
## 0..1: how roughly the material breaks. 0 = holes are round with a soft
## edge; 1 = they follow angular blocks of about fracture_size (and smaller),
## like chipped stone.
@export_range(0.0, 1.0) var fracture := 0.0
@export var fracture_size := 0.16
## 0..1: how much loose atoms hold together. 0 = each flies its own way (dust);
## near 1 = they break off as chunks of about clump_size that fly, bounce and
## land as one.
@export_range(0.0, 1.0) var clump := 0.0
@export var clump_size := 0.06
## How violently atoms fly from a hit (multiplies the hit's force).
@export var scatter := 1.0


## Glowing sparks that drift off and fade (the default behaviour).
static func ember() -> PointElement:
	return PointElement.new()


## Heavy grains: thrown hard, fall fast, bounce a little, stay where they land.
static func stone() -> PointElement:
	var e := PointElement.new()
	e.name = "Stone"
	e.fracture = 1.0
	e.fracture_size = 0.16
	e.clump = 0.85
	e.clump_size = 0.09
	e.gravity = 9.8
	e.lifetime = 0.0
	e.lands = true
	e.bounce = 0.35
	e.friction = 0.45
	e.glow = 0.0
	e.hardness = 1.15
	e.scatter = 1.15
	return e


## Bouncy beads that keep hopping before they settle.
static func rubber() -> PointElement:
	var e := stone()
	e.name = "Rubber"
	e.bounce = 0.8
	e.friction = 0.15
	e.hardness = 1.0
	e.scatter = 1.4
	return e


## Light dust: bursts out, is stopped by the air and sinks slowly.
static func dust() -> PointElement:
	var e := PointElement.new()
	e.name = "Dust"
	e.gravity = 0.8
	e.lifetime = 0.0
	e.lands = true
	e.bounce = 0.0
	e.friction = 1.0
	e.drag = 2.5
	e.glow = 0.0
	e.hardness = 0.8
	e.scatter = 2.5
	return e
