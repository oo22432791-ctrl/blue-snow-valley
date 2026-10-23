extends "res://scripts/ai/valley_bears.gd"
## 合作动物管理复用同一导航、尸体与声部，失败归属为实际攻击目标。

const COOP_BEAR = preload("res://scripts/v3/ai/valley_v3_bear.gd")


## 为原装配流程提供具有双角色目标选择能力的熊。
func _create_bear() -> CharacterBody3D:
	# 1. 原管理器继续唯一登记稳定ID和导航家域。
	return COOP_BEAR.new()


## 命中提交给抬掌锁定的角色，不对同伴造成友伤或转移伤害。
func attack_landed(bear: CharacterBody3D, serial: int) -> void:
	# 1. 一次失败立即冻结世界，第二只熊不能再提交交易或失败。
	if world.session.failure_barrier or serial <= bear.last_landed_attack_serial or serial > bear.attack_serial:
		return
	# 已被保护挡住的攻击也消费本次序号，不能十秒后重放同一掌。
	bear.last_landed_attack_serial = serial
	var model: Node = world.survival if bear.target_actor_id == "p1" else world.secondary_context.survival
	if not model.request_failure(&"bear_attack"):
		return
	_last_attack_at = world.world_clock.elapsed_seconds
	attack_events.append({"bear_id": bear.stable_id, "actor_id": bear.target_actor_id, "serial": serial, "at": world.world_clock.elapsed_seconds})
	if attack_events.size() > 32:
		attack_events.pop_front()
	attack_confirmed.emit(StringName(bear.stable_id), serial)


## 两处身体和所有显示视图共同阻止眼前尸体消失或熊重生。
func _away_from_view(at: Vector3) -> bool:
	# 1. 不把共享世界的生命周期误判成只围绕P1。
	return is_instance_valid(world.actor_registry) and world.actor_registry.away_from_observers(at)
