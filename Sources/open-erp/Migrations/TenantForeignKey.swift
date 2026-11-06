import Fluent

extension SchemaBuilder {
    func tenantForeignKey(_ field: FieldKey, references table: String) -> Self {
        foreignKey(["organization_id", field], references: table, ["organization_id", "id"], name: "\(field)_tenant_fk")
    }
}
