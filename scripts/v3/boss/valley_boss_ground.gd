extends Node3D
## 正式雪熊读取现有雪谷地形，世界坐标不重复叠加山门偏移。
var world: Node3D

func ground(at: Vector3) -> float:
	return world.terrain.get_ground_height(Vector2(at.x,at.z))
