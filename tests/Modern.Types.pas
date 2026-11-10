unit Modern.Types;

interface

uses System.SysUtils, System.Generics.Collections;

type
  /// Callback with a qualified parameter type.
  TCallback = reference to procedure(const Value: System.String);

  /// Generic container. Árvíztűrő tükörfúrógép.
  TBox<T: class, constructor> = class sealed(TObject)
  strict private
    FItems: TList<T>;
  strict protected
    function ReadItems: TList<T>;
  public
    /// Return nested generic types without losing their arguments.
    function Snapshot(const Source: System.Generics.Collections.TList<T>): TArray<TList<T>>;
    procedure Put(const Value: T);
    /// Generic method with its own type parameter.
    function Identity<TValue>(const Value: TValue): TValue;
    property Items: TList<T> read FItems;
  end;

  /// Advanced generic record.
  TPair<TKey; TValue> = record
  public
    function GetValue: TValue;
  end;

  /// A helper is documented as its own container.
  TStringHelper = record helper for string
  public
    function Trimmed: string;
  end;

  /// A generic descendant.
  TStringBox = class(TBox<TObject>)
  public
    procedure Clear;
  end;

  /// Generic alias.
  TBoxes = TList<TBox<TObject>>;

implementation

end.
