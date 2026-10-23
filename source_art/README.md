# Blender源文件

本目录保留项目内自制的可编辑模型与骨骼动画。`.gdignore`让Godot只导入`assets/models/`下的GLB，运行游戏不依赖Blender。

- `blender/snow_child.blend`：角色网格、七根骨骼、蒙皮和Idle/Walk/Run/Throw/Hit五段动作。
- `blender/winter_props.blend`：八个场景道具，分开放置便于编辑。

日常修改后使用`tools/export_blender_sources.py`从已有源文件重导出；它不保存覆盖`.blend`，并去掉道具的目录展示位移。`tools/build_blender_assets.py`会重建初始几何并覆盖源文件，不能用来保留手改内容。

完整命令、坐标与重导入检查见[开发说明](../docs/m5_implementation.md)。所有模型和动作由项目工具自制，没有第三方模型素材。

M7投掷与受击动作使用`tools/snowball_actions.py`定义；`add_snowball_actions.py`仅在需要重新生成两段动作时使用，会覆盖手改的Throw/Hit。M6源文件保留在`backups/m6_snow_child.blend`，当前M7运行要求五段动作。详见[M7动作与重导出说明](../docs/m7_implementation.md)。
