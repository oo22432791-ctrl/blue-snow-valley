# 运行模型

九个GLB由项目内的Blender源文件导出：一个骨骼角色，以及房屋、木棚、三种枯树、木栏、雪人和雪堆。

`manifest.json`记录来源、坐标、步距、三角面、材质、源文件和GLB哈希。不要直接修改导入缓存；源文件在`source_art/blender/`。

编辑、重导出与Godot导入说明见[开发说明](../../docs/m5_implementation.md)。所有模型和动画为项目内自制。

M7角色保留原网格和三段步态，追加Throw/Hit上身动作；当前清单包含五段动画。八个环境模型不变，见[M7验证](../../docs/m7_validation.md)。
