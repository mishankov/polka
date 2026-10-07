import { forwardRef, useId, type CSSProperties, type ComponentProps, type ReactNode } from 'react';

// Small shared controls for the desktop surfaces. Form fields retain native HTML semantics.
type Layout = {
  gap?: string | number;
  mt?: string | number;
  mb?: string | number;
  m?: string | number;
  mx?: string | number;
  p?: string | number;
  maw?: number;
  wrap?: string;
};
const space = (value?: string | number) =>
  typeof value === 'number'
    ? value
    : ({ xs: 6, sm: 10, md: 16, lg: 24, xl: 32 }[value || ''] ?? value);
function layout({ gap, mt, mb, m, mx, p, maw }: Layout): CSSProperties {
  return {
    gap: space(gap),
    margin: space(m),
    marginTop: space(mt),
    marginBottom: space(mb),
    marginInline: space(mx),
    padding: space(p),
    maxWidth: maw,
  };
}
type BoxProps = ComponentProps<'div'> & Layout;
export function Stack({
  gap,
  mt,
  mb,
  m,
  mx,
  p,
  maw,
  wrap,
  style,
  className = '',
  ...props
}: BoxProps) {
  return (
    <div
      {...props}
      className={`native-stack ${className}`}
      style={{ ...layout({ gap, mt, mb, m, mx, p, maw }), ...style }}
    />
  );
}
export function Group({
  gap,
  mt,
  mb,
  m,
  mx,
  p,
  maw,
  wrap,
  style,
  className = '',
  ...props
}: BoxProps) {
  return (
    <div
      {...props}
      className={`native-group ${className}`}
      style={{
        ...layout({ gap, mt, mb, m, mx, p, maw }),
        flexWrap: wrap === 'nowrap' ? 'nowrap' : 'wrap',
        ...style,
      }}
    />
  );
}
type ButtonProps = ComponentProps<'button'> & {
  variant?: string;
  color?: string;
  size?: string;
  loading?: boolean;
  leftSection?: ReactNode;
  mt?: string | number;
};
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {
    variant = 'filled',
    color,
    size,
    loading,
    leftSection,
    mt,
    disabled,
    className = '',
    children,
    ...props
  },
  ref,
) {
  return (
    <button
      type="button"
      {...props}
      ref={ref}
      style={{ marginTop: space(mt), ...props.style }}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      className={`native-button ${className}`}
      data-variant={variant}
      data-danger={color === 'red' || undefined}
    >
      {loading && <Loader aria-label="Выполняется" />}
      {leftSection}
      {children}
    </button>
  );
});
export const ActionIcon = forwardRef<HTMLButtonElement, ButtonProps>(function ActionIcon(
  { className = '', ...props },
  ref,
) {
  return <Button {...props} ref={ref} className={`native-icon-button ${className}`} />;
});
export function Text({
  size,
  c,
  fw,
  truncate,
  mt,
  mb,
  m,
  mx,
  p,
  maw,
  gap,
  wrap,
  style,
  className = '',
  ...props
}: BoxProps & { size?: string; c?: string; fw?: number; truncate?: boolean }) {
  return (
    <div
      {...props}
      className={`native-text ${className}`}
      data-muted={c === 'dimmed' || undefined}
      style={{
        ...layout({ mt, mb, m, mx, p, maw }),
        fontSize: size === 'xs' ? 11 : undefined,
        fontWeight: fw,
        ...(truncate
          ? ({
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            } as CSSProperties)
          : {}),
        ...style,
      }}
    />
  );
}
export function Title({
  order = 2,
  size,
  children,
  ...props
}: ComponentProps<'h2'> & { order?: 1 | 2 | 3; size?: string }) {
  const Heading = `h${order}` as 'h1' | 'h2' | 'h3';
  return <Heading {...props}>{children}</Heading>;
}
export function Alert({
  title,
  color,
  children,
  ...props
}: BoxProps & { title?: string; color?: string }) {
  return (
    <Stack {...props} className={`native-alert ${props.className || ''}`} role="alert">
      {title && <strong>{title}</strong>}
      {children}
    </Stack>
  );
}
export function Loader({
  size,
  color,
  ...props
}: ComponentProps<'span'> & { size?: string; color?: string }) {
  return <span role="status" aria-label="Загрузка" {...props} className="native-spinner" />;
}
export function Tooltip({ label, children }: { label: string; children: ReactNode }) {
  return (
    <span className="native-tooltip-anchor" title={label}>
      {children}
    </span>
  );
}
type InputProps = Omit<ComponentProps<'input'>, 'size'> & {
  label?: string;
  size?: string;
  leftSection?: ReactNode;
  rightSection?: ReactNode;
};
export const TextInput = forwardRef<HTMLInputElement, InputProps>(function TextInput(
  { label, leftSection, rightSection, size, id, className = '', ...props },
  ref,
) {
  const generated = useId();
  const inputId = id || generated;
  return (
    <div className={`native-field ${className}`}>
      {label && <label htmlFor={inputId}>{label}</label>}
      <div className="native-input-wrap">
        {leftSection && <span className="native-input-icon">{leftSection}</span>}
        <input {...props} id={inputId} ref={ref} />
        {rightSection}
      </div>
    </div>
  );
});
export function Textarea({
  label,
  id,
  className = '',
  ...props
}: ComponentProps<'textarea'> & { label: string }) {
  const generated = useId();
  const inputId = id || generated;
  return (
    <div className={`native-field ${className}`}>
      <label htmlFor={inputId}>{label}</label>
      <textarea {...props} id={inputId} />
    </div>
  );
}
export function Switch({
  label,
  description,
  id,
  ...props
}: Omit<ComponentProps<'input'>, 'type'> & { label: string; description?: string }) {
  const generated = useId();
  const inputId = id || generated;
  return (
    <div className="native-setting-row">
      <label htmlFor={inputId}>
        {label}
        {description && <span id={`${inputId}-description`}>{description}</span>}
      </label>
      <input
        {...props}
        id={inputId}
        type="checkbox"
        role="switch"
        aria-describedby={description ? `${inputId}-description` : undefined}
      />
    </div>
  );
}
export function Select({
  label,
  data,
  onChange,
  ...props
}: Omit<ComponentProps<'select'>, 'onChange'> & {
  label: string;
  data: { value: string; label: string }[];
  onChange: (value: string) => void;
}) {
  const id = useId();
  return (
    <div className="native-field">
      <label htmlFor={id}>{label}</label>
      <select {...props} id={id} onChange={(event) => onChange(event.currentTarget.value)}>
        {data.map((item) => (
          <option key={item.value} value={item.value}>
            {item.label}
          </option>
        ))}
      </select>
    </div>
  );
}
export function Progress(props: ComponentProps<'progress'>) {
  return <progress max={100} {...props} />;
}
