import { Global, Module } from '@nestjs/common';
import { TenantsService } from './tenants.service';

@Global()
@Module({
  providers: [TenantsService],
  exports: [TenantsService],
})
export class TenantsModule {}
