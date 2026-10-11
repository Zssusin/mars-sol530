# 对拍用的宿主桩：撒石.gd 需要 实景.gd 的 args、hash01、enu_basis。两个函数逐字抄自 实景.gd（2026-10-06 版）。
extends Node3D

var args := {}


func hash01(x: float, salt: float) -> float:
	return fposmod(sin(x*12.9898 + salt*78.233)*43758.5453, 1.0)


func enu_basis(rx: float, ry: float, rz: float, sx: float, sy: float, sz: float) -> Basis:
	"""ENU 里 R = Rz·Ry·Rx（Blender 欧拉 XYZ）再缩放 → Godot 基：G·M·Gᵀ。"""
	var M := Basis.from_euler(Vector3(rx, ry, rz), EULER_ORDER_XYZ)*Basis.from_scale(Vector3(sx, sy, sz))
	var G := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))   # 列：E→x、N→−z、U→y
	return G*M*G.transposed()
