//! Output data and rendering: text, tables, fields and JSON.

const result = @import("ui/result.zig");
const table = @import("ui/table.zig");
const syntax = @import("ui/syntax.zig");
const fields = @import("ui/fields.zig");
const output = @import("ui/output.zig");

pub const Error = result.Error;
pub const Failure = result.Failure;
pub const Result = result.Result;

pub const Table = table.Table;
pub const TableBuilder = table.TableBuilder;

pub const Arg = syntax.Arg;
pub const Param = syntax.Param;
pub const Flag = syntax.Flag;
pub const Command = syntax.Command;
pub const Help = syntax.Help;
pub const usage = syntax.usage;
pub const paramText = syntax.paramText;
pub const names = syntax.names;

pub const Val = fields.Val;
pub const Unit = fields.Unit;
pub const Format = fields.Format;
pub const Field = fields.Field;
pub const Fields = fields.Fields;
pub const bareText = fields.bareText;
pub const nameOr = fields.nameOr;

pub const Output = output.Output;
pub const render = output.render;
pub const renderDiagnostics = output.renderErr;

test {
    _ = result;
    _ = table;
    _ = syntax;
    _ = fields;
    _ = output;
}
