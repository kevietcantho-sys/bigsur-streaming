import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import type { Response } from 'express';

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('Exception');

  catch(exception: unknown, host: ArgumentsHost): void {
    const res = host.switchToHttp().getResponse<Response>();

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const body = exception.getResponse();
      res.status(status).json(
        typeof body === 'string' ? { error: body } : body,
      );
      return;
    }

    const err = exception as Error;
    this.logger.error(err?.message ?? 'Unknown error', err?.stack);
    res
      .status(HttpStatus.INTERNAL_SERVER_ERROR)
      .json({ error: 'internal' });
  }
}
