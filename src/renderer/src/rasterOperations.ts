export type RasterOperation =
  | { type: 'resize'; width: number; height: number }
  | { type: 'crop'; x: number; y: number; width: number; height: number }
  | { type: 'rotate'; direction: 'left' | 'right' }
  | { type: 'flip'; axis: 'horizontal' | 'vertical' };
export function validateRasterOperation(operation: RasterOperation, width: number, height: number) {
  if (operation.type === 'resize' || operation.type === 'crop') {
    if (
      !Number.isInteger(operation.width) ||
      !Number.isInteger(operation.height) ||
      operation.width < 1 ||
      operation.height < 1 ||
      operation.width > 8192 ||
      operation.height > 8192 ||
      operation.width * operation.height > 16_777_216
    )
      throw Error('Размер должен быть от 1 до 8192 пикселей, не более 16 мегапикселей');
    if (
      operation.type === 'crop' &&
      (!Number.isInteger(operation.x) ||
        !Number.isInteger(operation.y) ||
        operation.x < 0 ||
        operation.y < 0 ||
        operation.x + operation.width > width ||
        operation.y + operation.height > height)
    )
      throw Error('Область обрезки должна находиться внутри изображения');
  }
}
export function applyRasterOperation(canvas: HTMLCanvasElement, operation: RasterOperation) {
  validateRasterOperation(operation, canvas.width, canvas.height);
  const source = document.createElement('canvas');
  source.width = canvas.width;
  source.height = canvas.height;
  source.getContext('2d')!.drawImage(canvas, 0, 0);
  if (operation.type === 'resize' || operation.type === 'crop') {
    canvas.width = operation.width;
    canvas.height = operation.height;
  } else if (operation.type === 'rotate') {
    canvas.width = source.height;
    canvas.height = source.width;
  }
  const ctx = canvas.getContext('2d')!;
  ctx.save();
  ctx.globalCompositeOperation = 'source-over';
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (operation.type === 'resize') {
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
  } else if (operation.type === 'crop')
    ctx.drawImage(
      source,
      operation.x,
      operation.y,
      operation.width,
      operation.height,
      0,
      0,
      operation.width,
      operation.height,
    );
  else if (operation.type === 'rotate') {
    ctx.translate(canvas.width / 2, canvas.height / 2);
    ctx.rotate(operation.direction === 'right' ? Math.PI / 2 : -Math.PI / 2);
    ctx.drawImage(source, -source.width / 2, -source.height / 2);
  } else {
    ctx.translate(
      operation.axis === 'horizontal' ? canvas.width : 0,
      operation.axis === 'vertical' ? canvas.height : 0,
    );
    ctx.scale(operation.axis === 'horizontal' ? -1 : 1, operation.axis === 'vertical' ? -1 : 1);
    ctx.drawImage(source, 0, 0);
  }
  ctx.restore();
}
