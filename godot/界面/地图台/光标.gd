# 录屏用：把光标和点击涟漪画在最上层（Godot 在虚拟显示里没有真光标）。
extends Control

var T: Node
var 点击: Array = []                                  # [位置, 起始时间, 键]


func 点(pos: Vector2, 键: int) -> void:
	点击.append([pos, Time.get_ticks_msec()/1000.0, 键])


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	if T == null: return
	var s: float = 令.s
	var now := Time.get_ticks_msec()/1000.0
	for c in 点击.duplicate():
		var t: float = now - c[1]
		if t > 0.5: 点击.erase(c); continue
		var 色 := Color(1.0, 0.85, 0.3, 1.0 - t/0.5) if c[2] != 0 else Color(0.5, 0.8, 1.0, 1.0 - t/0.5)
		draw_arc(c[0], (10.0 + 40.0*t/0.5)*s, 0.0, TAU, 32, 色, 3.0*s, true)
	var p: Vector2 = T.光标位
	if p.x < 0: return
	var pts := PackedVector2Array([p, p + Vector2(0, 26)*s, p + Vector2(7, 20)*s, p + Vector2(13, 31)*s, p + Vector2(18, 28)*s, p + Vector2(12, 18)*s, p + Vector2(21, 18)*s])
	draw_colored_polygon(pts, Color(0, 0, 0, 0.9))
	var 内 := PackedVector2Array()
	for q in pts: 内.append(p + (q - p)*0.82 + Vector2(1, 2)*s)
	draw_colored_polygon(内, Color(1, 1, 1, 1))
