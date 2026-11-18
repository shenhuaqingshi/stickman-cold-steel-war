/**
 * ArkUI CanvasRenderingContext2D 到渲染层 ICanvas2DContext 的显式名义类型适配器（ArkCanvas2DAdapter.ets）
 * 严格遵循 ArkTS 名义类型规范（arkts-no-structural-typing，零 any / unknown），
 * 每个页面仅实例化 1 次，帧循环内零临时对象分配。
 */
import {
  CanvasLineCapMode,
  CanvasLineJoinMode,
  CanvasStyleValue,
  CanvasTextAlignMode,
  CanvasTextBaselineMode,
  ICanvas2DContext
} from '../render/StickmanBattleRenderer';

export class ArkCanvas2DAdapter implements ICanvas2DContext {
  private readonly raw: CanvasRenderingContext2D;
  private cachedFillStyle: CanvasStyleValue = '#000000';
  private cachedStrokeStyle: CanvasStyleValue = '#000000';
  private cachedLineWidth: number = 1.0;
  private cachedLineCap: CanvasLineCapMode = 'round';
  private cachedLineJoin: CanvasLineJoinMode = 'round';
  private cachedGlobalAlpha: number = 1.0;
  private cachedFont: string = '14px sans-serif';
  private cachedTextAlign: CanvasTextAlignMode = 'left';
  private cachedTextBaseline: CanvasTextBaselineMode = 'alphabetic';

  public constructor(raw: CanvasRenderingContext2D) {
    this.raw = raw;
  }

  public get fillStyle(): CanvasStyleValue {
    return this.cachedFillStyle;
  }

  public set fillStyle(value: CanvasStyleValue) {
    this.cachedFillStyle = value;
    if (typeof value === 'string' || typeof value === 'number') {
      this.raw.fillStyle = value;
    }
  }

  public get strokeStyle(): CanvasStyleValue {
    return this.cachedStrokeStyle;
  }

  public set strokeStyle(value: CanvasStyleValue) {
    this.cachedStrokeStyle = value;
    if (typeof value === 'string' || typeof value === 'number') {
      this.raw.strokeStyle = value;
    }
  }

  public get lineWidth(): number {
    return this.cachedLineWidth;
  }

  public set lineWidth(value: number) {
    this.cachedLineWidth = value;
    this.raw.lineWidth = value;
  }

  public get lineCap(): CanvasLineCapMode {
    return this.cachedLineCap;
  }

  public set lineCap(value: CanvasLineCapMode) {
    this.cachedLineCap = value;
    this.raw.lineCap = value;
  }

  public get lineJoin(): CanvasLineJoinMode {
    return this.cachedLineJoin;
  }

  public set lineJoin(value: CanvasLineJoinMode) {
    this.cachedLineJoin = value;
    this.raw.lineJoin = value;
  }

  public get globalAlpha(): number {
    return this.cachedGlobalAlpha;
  }

  public set globalAlpha(value: number) {
    this.cachedGlobalAlpha = value;
    this.raw.globalAlpha = value;
  }

  public get font(): string {
    return this.cachedFont;
  }

  public set font(value: string) {
    this.cachedFont = value;
    this.raw.font = value;
  }

  public get textAlign(): CanvasTextAlignMode {
    return this.cachedTextAlign;
  }

  public set textAlign(value: CanvasTextAlignMode) {
    this.cachedTextAlign = value;
    this.raw.textAlign = value;
  }

  public get textBaseline(): CanvasTextBaselineMode {
    return this.cachedTextBaseline;
  }

  public set textBaseline(value: CanvasTextBaselineMode) {
    this.cachedTextBaseline = value;
    this.raw.textBaseline = value;
  }

  public save(): void {
    this.raw.save();
  }

  public restore(): void {
    this.raw.restore();
  }

  public clearRect(x: number, y: number, w: number, h: number): void {
    this.raw.clearRect(x, y, w, h);
  }

  public fillRect(x: number, y: number, w: number, h: number): void {
    this.raw.fillRect(x, y, w, h);
  }

  public strokeRect(x: number, y: number, w: number, h: number): void {
    this.raw.strokeRect(x, y, w, h);
  }

  public beginPath(): void {
    this.raw.beginPath();
  }

  public closePath(): void {
    this.raw.closePath();
  }

  public moveTo(x: number, y: number): void {
    this.raw.moveTo(x, y);
  }

  public lineTo(x: number, y: number): void {
    this.raw.lineTo(x, y);
  }

  public arc(
    x: number,
    y: number,
    radius: number,
    startAngle: number,
    endAngle: number,
    counterclockwise?: boolean
  ): void {
    this.raw.arc(x, y, radius, startAngle, endAngle, counterclockwise);
  }

  public ellipse(
    x: number,
    y: number,
    radiusX: number,
    radiusY: number,
    rotation: number,
    startAngle: number,
    endAngle: number,
    counterclockwise?: boolean
  ): void {
    this.raw.ellipse(x, y, radiusX, radiusY, rotation, startAngle, endAngle, counterclockwise);
  }

  public quadraticCurveTo(cpx: number, cpy: number, x: number, y: number): void {
    this.raw.quadraticCurveTo(cpx, cpy, x, y);
  }

  public fill(): void {
    this.raw.fill();
  }

  public stroke(): void {
    this.raw.stroke();
  }

  public translate(x: number, y: number): void {
    this.raw.translate(x, y);
  }

  public scale(x: number, y: number): void {
    this.raw.scale(x, y);
  }

  public rotate(angle: number): void {
    this.raw.rotate(angle);
  }

  public fillText(text: string, x: number, y: number, maxWidth?: number): void {
    if (maxWidth !== undefined) {
      this.raw.fillText(text, x, y, maxWidth);
    } else {
      this.raw.fillText(text, x, y);
    }
  }

  public setLineDash(segments: number[]): void {
    this.raw.setLineDash(segments);
  }
}
